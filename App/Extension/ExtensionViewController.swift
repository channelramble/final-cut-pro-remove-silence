import AppKit

/// Principal view controller of the workflow extension. Final Cut Pro instantiates it by the
/// Objective-C name given in Info.plist (ProExtensionPrincipalViewControllerClass) and shows
/// its view in the extension window (the Extensions button in the toolbar, or
/// Window > Extensions).
@objc(SilenceRemoverExtensionViewController)
final class SilenceRemoverExtensionViewController: RemoverViewController {
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        // There is no nib; the view is built in code.
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
