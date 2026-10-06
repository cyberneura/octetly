import Foundation

/// Where a file that ships with the app is, whichever way the app was built.
///
/// `swift run` leaves resources in the SwiftPM resource bundle beside the executable, and that is
/// what `Bundle.module` finds. The released build is a real .app (`scripts/make-app.sh`) and
/// carries them in `Contents/Resources` instead, because the SwiftPM bundle cannot go where
/// `Bundle.module` looks for it: the generated accessor looks for it inside `Bundle.main.bundleURL`,
/// which for an app is the top level of the .app, where nothing but `Contents` may live and where
/// anything else breaks the signature.
///
/// The .app is asked first rather than second because `Bundle.module` is a `fatalError`
/// when it finds nothing, not a nil — reaching it at all is what has to be avoided in the .app.
enum BundledResource {
    /// The .app this executable is part of, or the main bundle when it is not in one.
    ///
    /// Not `Bundle.main` alone: run through a symbolic link, as the command-line tool is, the main
    /// bundle is the folder the link is in. It then has no Info.plist and no resources, and the
    /// lookup falls through to `Bundle.module` and its `fatalError`.
    static let app: Bundle = {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return .main }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app) else { return .main }
        return bundle
    }()

    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        if let url = app.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: fileExtension)
    }
}
