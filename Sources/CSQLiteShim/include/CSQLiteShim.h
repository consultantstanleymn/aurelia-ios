/* Re-exports the system SQLite header as a Swift module.
 *
 * This exists so `swift test` can exercise ProgressStore on Linux.
 *
 * The Darwin SDK ships a SQLite3 module, so the iOS build imports it directly and never needs
 * this. Linux has the headers and the library but no Clang module map for them, which meant
 * `canImport(SQLite3)` was false there — and because every method in ProgressStore.swift sits
 * behind that check, the entire store compiled to nothing under `swift test`. Not one of its six
 * queries had ever been executed by anything, on either platform.
 *
 * SwiftPM generates the module map for a C target from its include directory, which is why this is
 * a target rather than a hand-written module.modulemap with an absolute path in it. Needs
 * sqlite-devel; the README says so.
 */
#ifndef CSQLITE_SHIM_H
#define CSQLITE_SHIM_H

#include <sqlite3.h>

#endif /* CSQLITE_SHIM_H */