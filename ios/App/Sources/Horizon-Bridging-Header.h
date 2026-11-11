// The game (ios/rust/horizon-ios): starts it on the main thread; never returns.
#include <stdnoreturn.h>
noreturn void horizon_ios_run(int argc, const char *const *argv);

#include <stddef.h>
// Builds prepared resources from the facts pack and the player's jar and assets; NULL when done,
// else an error to free with horizon_ios_free_string.
typedef void (*horizon_assemble_progress)(size_t done, size_t total, void *context);
char *horizon_ios_assemble(const char *facts, const char *client_jar, const char *assets,
                           const char *out, horizon_assemble_progress progress, void *context);
void horizon_ios_free_string(char *text);
// Unpacks a zip into a folder (world import); NULL when done, else an error to free.
char *horizon_ios_unzip(const char *archive, const char *out);
// Horizon's mod registry: checks a downloaded file against index.json (NULL: it passes), and
// reads a content mod's manifest as JSON. Free both results with horizon_ios_free_string.
char *horizon_ios_mod_check(const char *index, const char *id, const char *version, const char *file);
char *horizon_ios_mod_manifest(const char *file);
// Game controllers (GameController framework → the game's controller path). family: 0 Xbox,
// 1 PlayStation, 2 Nintendo, else unknown. buttons: bits in gamepad::Button's order (south, east,
// west, north, LB, RB, LT, RT, select, start, LS, RS, up, down, left, right); sticks up positive.
#include <stdint.h>
void horizon_ios_pad_connected(int family, const char *name);
void horizon_ios_pad_disconnected(void);
void horizon_ios_pad_state(uint32_t buttons, float lx, float ly, float rx, float ry, float lt, float rt);
