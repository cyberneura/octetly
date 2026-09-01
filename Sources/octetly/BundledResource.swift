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
/// The main bundle is asked first rather than second because `Bundle.module` is a `fatalError`
/// when it finds nothing, not a nil — reaching it at all is what has to be avoided in the .app.
enum BundledResource {
    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: fileExtension)
    }
}
