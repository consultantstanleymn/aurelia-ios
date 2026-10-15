import XCTest
@testable import StudyBuddyCore

/// Finding the staged curricula inside a built app.
///
/// This is the one piece of the content pipeline that could not be tested before, and it was the
/// one that was broken. The app reads its curricula from its own bundle, and the build puts them in
/// a *nested* resource bundle rather than the app's resources, so the original lookup found nothing
/// and the tutor ran with no material at all — zero days on every track, no error anywhere, and a
/// turn that completed perfectly while knowing nothing.
///
/// It was only visible on the device, in `content.loaded days=0`, and the lookup read
/// `Bundle.main.resourceURL`, which is not something a Linux test can point anywhere useful. So the
/// search is a pure function over a directory, and these tests build the two layouts by hand — the
/// real one and the one the app actually ships.
final class ContentRootDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aurelia-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeContent(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("aws-sa-pro-curriculum"), withIntermediateDirectories: true
        )
        return url
    }

    /// The layout the build produces: resources declared on the app target land in a nested
    /// `<package>_<target>.bundle`. This is the one that returned nil and emptied the tutor.
    func testContentIsFoundInsideANestedResourceBundle() throws {
        let bundle = root.appendingPathComponent("Aurelia_Aurelia.bundle", isDirectory: true)
        let content = try makeContent(at: bundle.appendingPathComponent("Content", isDirectory: true))

        let found = ContentStore.findContentRoot(in: root)
        XCTAssertEqual(found?.standardizedFileURL.path, content.standardizedFileURL.path)
    }

    /// The layout where the resources sit directly in the app. Kept working, because that is what a
    /// flat copy or a differently-configured build gives.
    func testContentIsFoundAtTheTopLevel() throws {
        let content = try makeContent(at: root.appendingPathComponent("Content", isDirectory: true))
        XCTAssertEqual(
            ContentStore.findContentRoot(in: root)?.standardizedFileURL.path,
            content.standardizedFileURL.path
        )
    }

    /// The name of the nested bundle follows the package and target names, so it is searched for
    /// rather than hard-coded. A bundle with any other name is still found.
    func testTheBundleNameDoesNotMatter() throws {
        let bundle = root.appendingPathComponent("SomethingElse_Other.bundle", isDirectory: true)
        _ = try makeContent(at: bundle.appendingPathComponent("Content", isDirectory: true))
        XCTAssertNotNil(ContentStore.findContentRoot(in: root))
    }

    /// An app with no staged content must say so rather than silently finding nothing — the whole
    /// failure was that it looked like success.
    func testNothingStagedIsFoundAsNothing() throws {
        XCTAssertNil(ContentStore.findContentRoot(in: root))
        XCTAssertNil(ContentStore.findContentRoot(in: nil))
    }

    /// A bundle that exists but holds no curricula must not be mistaken for one that does.
    func testABundleWithoutContentIsNotMistakenForIt() throws {
        let bundle = root.appendingPathComponent("Aurelia_Aurelia.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertNil(ContentStore.findContentRoot(in: root))
    }

    /// Directories that are not resource bundles are ignored, and a stray file called "Content" does
    /// not pass for the directory.
    func testFilesAreNotMistakenForTheDirectory() throws {
        try "not a directory".write(
            to: root.appendingPathComponent("Content"), atomically: true, encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Some.framework"), withIntermediateDirectories: true
        )
        XCTAssertNil(ContentStore.findContentRoot(in: root))
    }

    /// The choice has to be stable when more than one candidate matches, or the same app could load
    /// different material on different launches.
    func testTheChoiceIsStableWhenSeveralMatch() throws {
        _ = try makeContent(at: root.appendingPathComponent("Aurelia_Aurelia.bundle/Content", isDirectory: true))
        _ = try makeContent(at: root.appendingPathComponent("Zebra_Zebra.bundle/Content", isDirectory: true))
        let first = ContentStore.findContentRoot(in: root)
        let second = ContentStore.findContentRoot(in: root)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first?.path.contains("Aurelia_Aurelia.bundle") == true)
    }
}