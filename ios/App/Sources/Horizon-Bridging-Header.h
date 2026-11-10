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
