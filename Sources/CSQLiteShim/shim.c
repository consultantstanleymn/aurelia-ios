/* Nothing to compile. The target exists for its header, which is what SwiftPM turns into the
 * module map that lets Swift see sqlite3 on Linux.
 *
 * An empty translation unit is not valid C, so this stands in for one and is never called.
 */
typedef int CSQLiteShimPlaceholder;