// Translate-c entry point for nix's C API, in dependency order. The bindings
// are generated from these headers at build time, so a signature change in nix
// surfaces as a compile error rather than as silent breakage.
// nix_api_value.h is deliberately absent: it carries a C23 [[deprecated]]
// attribute on a typedef, which clang rejects in translate-c's default C mode,
// and nothing else includes it. The few functions it declares are hand declared
// in nix.zig instead. Recheck on a nix upgrade.
#include <nix_api_util.h>
#include <nix_api_store.h>
#include <nix_api_expr.h>
#include <nix_api_fetchers.h>
#include <nix_api_flake.h>
