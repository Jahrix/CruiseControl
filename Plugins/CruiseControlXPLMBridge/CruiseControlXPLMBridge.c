/*
 CruiseControl XPLM bridge — Phase 10 safety prototype.

 Build this source against the official X-Plane SDK; it is deliberately not
 linked into the macOS app. All XPLM calls occur in cc_flight_loop(), never in
 an IPC thread. sim/private/controls/reno/LOD_bias_rat remains unsupported:
 SDK discovery creates only a candidate, and a user-triggered verification
 transaction must pass multi-frame persistence and restoration before writes.
*/
#include "XPLMPlugin.h"
#include "XPLMDataAccess.h"
#include "XPLMProcessing.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CC_PROTOCOL 1
#define CC_PORT 49006
#define CC_MIN_LOD 0.20f
#define CC_MAX_LOD 3.00f
#define CC_TOLERANCE 0.01f
#define CC_VERIFY_FRAMES 3
#define CC_MIN_WRITE_SECONDS 1.0
#define CC_LEASE_SECONDS 5.0
#define CC_LOD_DATAREF "sim/private/controls/reno/LOD_bias_rat"

typedef enum { CC_UNAVAILABLE, CC_CANDIDATE, CC_VERIFY_WRITE, CC_VERIFY_RESTORE,
    CC_VERIFIED_IDLE, CC_APPLY_WRITE, CC_LEASE_RESTORE, CC_LOCKED_OUT, CC_RECOVERY_REQUIRED } CCState;

typedef struct {
    char nonce[80];
    char controller[80];
    unsigned long long sequence;
    float requested;
    float original;
    int matching_frames;
    int write_issued;
    int verification;
    struct sockaddr_in reply_to;
    socklen_t reply_length;
} CCTransaction;

static XPLMDataRef g_lod = NULL;
static CCState g_state = CC_UNAVAILABLE;
static CCTransaction g_tx;
static int g_has_tx = 0;
static int g_socket = -1;
static char g_session[48];
static char g_build[48];
static char g_simulator_version[8];
static char g_last_nonce[80];
static char g_controller_lease[80];
static unsigned long long g_last_sequence = 0;
static float g_activation_original = 0.0f;
static int g_has_activation_original = 0;
static float g_last_write_at = -1000.0f;
static float g_lease_expires_at = 0.0f;

static int cc_in_range(float value) { return value >= CC_MIN_LOD && value <= CC_MAX_LOD; }
static int cc_matches(float a, float b) { return a == a && b == b && a - b < CC_TOLERANCE && b - a < CC_TOLERANCE; }
static const char *cc_state_name(CCState state) {
    switch (state) {
        case CC_CANDIDATE: return "candidate"; case CC_VERIFY_WRITE: return "verifying_persistence";
        case CC_VERIFY_RESTORE: return "verifying_restoration"; case CC_VERIFIED_IDLE: return "verified_idle";
        case CC_APPLY_WRITE: return "applying"; case CC_LEASE_RESTORE: return "restoring";
        case CC_LOCKED_OUT: return "locked_out"; case CC_RECOVERY_REQUIRED: return "recovery_required";
        default: return "unavailable";
    }
}

static void cc_session_id(void) {
    snprintf(g_session, sizeof(g_session), "%08x-%08x", arc4random(), arc4random());
}

static void cc_reply(const char *result, float observed) {
    char buffer[384];
    if (!g_has_tx || g_socket < 0) return;
    snprintf(buffer, sizeof(buffer), "CCLOD/%d RESULT %s %s %llu %s %.3f %.3f %s\n",
        CC_PROTOCOL, g_session, g_tx.nonce, g_tx.sequence, result, g_tx.requested, observed, cc_state_name(g_state));
    sendto(g_socket, buffer, strlen(buffer), 0, (struct sockaddr *)&g_tx.reply_to, g_tx.reply_length);
}

/* The status is advisory evidence; an app must still match session+nonce+seq. */
static void cc_status(void) {
    char path[1024], folder[900]; const char *home = getenv("HOME"); FILE *file;
    if (!home || !g_lod) return;
    snprintf(folder, sizeof(folder), "%s/Library/Containers/jahrix.CruiseControl/Data/Library/Application Support/CruiseControl", home);
    snprintf(path, sizeof(path), "%s/lod_status.txt", folder);
    file = fopen(path, "w"); if (!file) return;
    fprintf(file, "protocol_version=%d\nplugin_session_id=%s\nsimulator_build=%s\nsimulator_version=%s\n", CC_PROTOCOL, g_session, g_build, g_simulator_version);
    fprintf(file, "lod_candidate=%s\nlod_write_supported=%s\ntransaction_state=%s\n", g_state == CC_CANDIDATE ? "true" : "false", g_state == CC_VERIFIED_IDLE ? "true" : "false", cc_state_name(g_state));
    fprintf(file, "current_lod=%.3f\n", XPLMGetDataf(g_lod));
    if (g_has_tx) fprintf(file, "last_nonce=%s\nlast_sequence=%llu\nrequested_lod=%.3f\n", g_tx.nonce, g_tx.sequence, g_tx.requested);
    else if (g_last_nonce[0]) fprintf(file, "last_nonce=%s\nlast_sequence=%llu\n", g_last_nonce, g_last_sequence);
    fprintf(file, "last_update_epoch=%ld\n", (long)time(NULL)); fclose(file);
}

static void cc_finish(const char *result, float observed, CCState next) {
    cc_reply(result, observed);
    if (!strcmp(result, "VERIFIED")) strncpy(g_controller_lease, g_tx.controller, sizeof(g_controller_lease) - 1);
    strncpy(g_last_nonce, g_tx.nonce, sizeof(g_last_nonce) - 1);
    g_last_sequence = g_tx.sequence; g_has_tx = 0; g_state = next; cc_status();
}

static void cc_fail(const char *result) {
    float observed = g_lod ? XPLMGetDataf(g_lod) : 0.0f;
    cc_finish(result, observed, g_tx.verification ? CC_LOCKED_OUT : CC_RECOVERY_REQUIRED);
}

static void cc_begin_verify(const char *controller, const char *nonce, unsigned long long seq, struct sockaddr_in *reply, socklen_t reply_len) {
    float original, delta;
    if (g_state != CC_CANDIDATE || g_has_tx || seq <= g_last_sequence || !strcmp(nonce, g_last_nonce)) return;
    original = XPLMGetDataf(g_lod); if (!cc_in_range(original)) { g_state = CC_LOCKED_OUT; cc_status(); return; }
    delta = original <= CC_MAX_LOD - 0.01f ? 0.01f : -0.01f;
    memset(&g_tx, 0, sizeof(g_tx)); strncpy(g_tx.controller, controller, sizeof(g_tx.controller)-1); strncpy(g_tx.nonce, nonce, sizeof(g_tx.nonce)-1);
    g_tx.sequence = seq; g_tx.original = original; g_tx.requested = original + delta; g_tx.verification = 1; g_tx.reply_to = *reply; g_tx.reply_length = reply_len; g_has_tx = 1; g_state = CC_VERIFY_WRITE;
}

static void cc_begin_write(const char *controller, const char *nonce, unsigned long long seq, float requested, struct sockaddr_in *reply, socklen_t reply_len) {
    float current = XPLMGetDataf(g_lod);
    if (g_state != CC_VERIFIED_IDLE || g_has_tx || !g_controller_lease[0] || strcmp(controller, g_controller_lease) || !cc_in_range(requested) || seq <= g_last_sequence || !strcmp(nonce, g_last_nonce) || XPLMGetElapsedTime() - g_last_write_at < CC_MIN_WRITE_SECONDS) return;
    if (!g_has_activation_original) { g_activation_original = current; g_has_activation_original = 1; }
    memset(&g_tx, 0, sizeof(g_tx)); strncpy(g_tx.controller, controller, sizeof(g_tx.controller)-1); strncpy(g_tx.nonce, nonce, sizeof(g_tx.nonce)-1);
    g_tx.sequence = seq; g_tx.original = current; g_tx.requested = requested; g_tx.reply_to = *reply; g_tx.reply_length = reply_len; g_has_tx = 1; g_lease_expires_at = XPLMGetElapsedTime() + CC_LEASE_SECONDS; g_state = CC_APPLY_WRITE;
}

static void cc_poll_commands(void) {
    char buffer[320], command[24], controller[80], nonce[80]; unsigned long long sequence; float value; struct sockaddr_in from; socklen_t length = sizeof(from); int count;
    while ((count = recvfrom(g_socket, buffer, sizeof(buffer)-1, 0, (struct sockaddr *)&from, &length)) > 0) {
        buffer[count] = '\0'; command[0] = controller[0] = nonce[0] = '\0'; value = 0;
        if (sscanf(buffer, "CCLOD/%*d %23s %79s %79s %llu %f", command, controller, nonce, &sequence, &value) < 4) continue;
        if (!strcmp(command, "VERIFY")) cc_begin_verify(controller, nonce, sequence, &from, length);
        else if (!strcmp(command, "SET")) cc_begin_write(controller, nonce, sequence, value, &from, length);
    }
}

static float cc_flight_loop(float elapsed1, float elapsed2, int counter, void *refcon) {
    float observed, expected;
    (void)elapsed1; (void)elapsed2; (void)counter; (void)refcon;
    cc_poll_commands();
    if (g_state == CC_VERIFIED_IDLE && g_has_activation_original && XPLMGetElapsedTime() >= g_lease_expires_at && !g_has_tx) {
        memset(&g_tx, 0, sizeof(g_tx)); strcpy(g_tx.nonce, "lease-expired"); g_tx.sequence = g_last_sequence + 1; g_tx.original = g_activation_original; g_tx.requested = g_activation_original; g_has_tx = 1; g_state = CC_LEASE_RESTORE;
    }
    if (!g_has_tx) { cc_status(); return -1.0f; }
    /* Set once, then observe across subsequent flight-loop frames. Repeating
       the write here would conceal a dataref that immediately reverts. */
    if (!g_tx.write_issued && (g_state == CC_VERIFY_WRITE || g_state == CC_APPLY_WRITE)) {
        XPLMSetDataf(g_lod, g_tx.requested);
        g_tx.write_issued = 1;
    }
    if (!g_tx.write_issued && (g_state == CC_VERIFY_RESTORE || g_state == CC_LEASE_RESTORE)) {
        XPLMSetDataf(g_lod, g_tx.original);
        g_tx.write_issued = 1;
    }
    observed = XPLMGetDataf(g_lod); expected = (g_state == CC_VERIFY_RESTORE || g_state == CC_LEASE_RESTORE) ? g_tx.original : g_tx.requested;
    if (!cc_matches(observed, expected)) { cc_fail("FAILED"); return -1.0f; }
    if (++g_tx.matching_frames < CC_VERIFY_FRAMES) return -1.0f;
    g_tx.matching_frames = 0;
    if (g_state == CC_VERIFY_WRITE) { g_state = CC_VERIFY_RESTORE; g_tx.write_issued = 0; return -1.0f; }
    if (g_state == CC_VERIFY_RESTORE) { cc_finish("VERIFIED", observed, CC_VERIFIED_IDLE); return -1.0f; }
    if (g_state == CC_LEASE_RESTORE) {
        g_has_activation_original = 0;
        g_controller_lease[0] = '\0';
        cc_finish("RESTORED", observed, CC_CANDIDATE);
        return -1.0f;
    }
    g_last_write_at = XPLMGetElapsedTime(); cc_finish("APPLIED", observed, CC_VERIFIED_IDLE); return -1.0f;
}

PLUGIN_API int XPluginStart(char *name, char *sig, char *desc) {
    int xp, sdk, host; int flags; struct sockaddr_in address;
    strcpy(name, "CruiseControl XPLM Bridge"); strcpy(sig, "jahrix.cruisecontrol.xplmbridge"); strcpy(desc, "Verified Adaptive LOD bridge");
    XPLMGetVersions(&xp, &sdk, &host); snprintf(g_build, sizeof(g_build), "XP%d-SDK%d", xp, sdk); snprintf(g_simulator_version, sizeof(g_simulator_version), "%s", xp >= 12000 ? "XP12" : xp >= 11000 ? "XP11" : "UNKNOWN"); cc_session_id();
    g_lod = XPLMFindDataRef(CC_LOD_DATAREF); flags = g_lod ? XPLMGetDataRefTypes(g_lod) : 0;
    if (g_lod && (flags & xplmType_Float) && XPLMCanWriteDataRef(g_lod)) g_state = CC_CANDIDATE; else g_state = CC_UNAVAILABLE;
    g_socket = socket(AF_INET, SOCK_DGRAM, 0); memset(&address, 0, sizeof(address)); address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(CC_PORT);
    if (g_socket < 0 || bind(g_socket, (struct sockaddr *)&address, sizeof(address)) < 0) { if (g_socket >= 0) close(g_socket); g_socket = -1; }
    else fcntl(g_socket, F_SETFL, O_NONBLOCK);
    XPLMRegisterFlightLoopCallback(cc_flight_loop, -1.0f, NULL); cc_status(); return 1;
}
PLUGIN_API void XPluginStop(void) { if (g_has_activation_original && g_lod) XPLMSetDataf(g_lod, g_activation_original); if (g_socket >= 0) close(g_socket); }
PLUGIN_API int XPluginEnable(void) { return 1; }
PLUGIN_API void XPluginDisable(void) { if (g_has_activation_original && g_lod) XPLMSetDataf(g_lod, g_activation_original); g_state = CC_RECOVERY_REQUIRED; cc_status(); }
PLUGIN_API void XPluginReceiveMessage(XPLMPluginID from, int message, void *param) { (void)from; (void)message; (void)param; }
