// The launcher's helpers (ios/rust/horizon-ios-tools). The game itself is a framework that
// GameBridge.swift loads at Play and calls horizon_ios_run in.

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
// Game controllers: horizon_ios_pad_* live in the game framework (GameBridge.Pad looks them up).
