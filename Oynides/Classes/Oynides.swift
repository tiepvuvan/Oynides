//
//  Oynides.swift
//  Oynides
//
//  Created by Peter Vu on 6/16/16.
//  Copyright © 2016 Peter Vu. All rights reserved.
//

import Foundation
import SSKeychain
import LocalAuthentication

private let UserDefaultKeyBiometricsAuthenticationActivatedSuffix = "UserDefaultKeyBiometricsAuthenticationActivatedSuffix"

private extension LAContext {
    private var haveBiometricsAuthentication: Bool {
        var error: NSError?
        let result = canEvaluatePolicy(.DeviceOwnerAuthenticationWithBiometrics, error: &error)
        
        if error != nil {
            return false
        } else {
            return result
        }
    }
}

private extension UIViewController {
    var topMostController: UIViewController {
        var topPresentedController: UIViewController = self
        while topPresentedController.presentedViewController != nil {
            topPresentedController = topPresentedController.presentedViewController!
        }
        return topPresentedController
    }
}

public enum UnLockType {
    case Biometrics, Passcode(String)
}

public typealias UnlockResultHandler = (UnlockResult) -> (Void)
public enum UnlockResult {
    case Success, Failure(ErrorType)
}

public enum PasscodeUnlockError: ErrorType {
    case InvalidPasscode
}

public class Lock {
    private let identifier: String
    private let keychainServiceName: String
    private let keychainAccountName: String
    public private(set) lazy var authenticationContext = LAContext()
    public var localizedBiometricsUnlockReason: String = "Enter passcode"

    public var shouldUseBiometricsAuthentication: Bool {
        get {
            return NSUserDefaults.standardUserDefaults().boolForKey(touchIdActivatedUserDefaultKey) && authenticationContext.haveBiometricsAuthentication
        } set {
            let userDefault = NSUserDefaults.standardUserDefaults()
            userDefault.setBool(newValue, forKey: touchIdActivatedUserDefaultKey)
            userDefault.synchronize()
        }
    }
    
    private var touchIdActivatedUserDefaultKey: String { return identifier + UserDefaultKeyBiometricsAuthenticationActivatedSuffix }
    
    public var passcode: String? {
        get {
            return SSKeychain.passwordForService(keychainServiceName, account: keychainAccountName)
        } set {
            if newValue == nil {
                SSKeychain.deletePasswordForService(keychainServiceName, account: keychainAccountName)
            } else {
                SSKeychain.setPassword(newValue, forService: keychainServiceName, account: keychainAccountName)
            }
        }
    }
    public var havePasscode: Bool { return passcode != nil }
    
    public func validatePasscode(passcode: String) -> Bool {
        if let currentPasscode = self.passcode {
            return currentPasscode == passcode
        } else {
            return false
        }
    }
    
    public init(identifier: String, keychainServiceName: String, keychainAccountName: String) {
        self.identifier = identifier
        self.keychainAccountName = keychainAccountName
        self.keychainServiceName = keychainServiceName
        authenticationContext.localizedFallbackTitle = "Enter passcode"
        
        if NSUserDefaults.standardUserDefaults().objectForKey(touchIdActivatedUserDefaultKey) == nil {
            shouldUseBiometricsAuthentication = true
        }
    }
    
    internal func unlockWithType(type: UnLockType, resultHandler: UnlockResultHandler? = nil) {
        switch type {
            case .Biometrics:
                if !authenticationContext.haveBiometricsAuthentication || !shouldUseBiometricsAuthentication {
                    resultHandler?(.Failure(LAError.TouchIDNotAvailable))
                    return
                }
                
                authenticationContext.evaluatePolicy(.DeviceOwnerAuthenticationWithBiometrics, localizedReason: localizedBiometricsUnlockReason) { success, error in
                    if let error = error as? LAError {
                        resultHandler?(.Failure(error))
                    } else if success {
                        resultHandler?(.Success)
                    }
                }
            case .Passcode(let passcode):
                if !validatePasscode(passcode) {
                    resultHandler?(.Failure(PasscodeUnlockError.InvalidPasscode))
                } else {
                    resultHandler?(.Success)
                }
        }
    }
}

public protocol LockAppearanceContentProvider {
    func splashScreenViewControllerForLockHandler(lockHandler: LockHandler) -> UIViewController
}

public class DefaultLockAppearanceProvider: LockAppearanceContentProvider {
    public func splashScreenViewControllerForLockHandler(lockHandler: LockHandler) -> UIViewController {
        return UIViewController()
    }
}

public class LockHandler {
    public let lock: Lock
    private let notificationCenter: NSNotificationCenter = .defaultCenter()
    private var splashViewController: UIViewController?
    private var locked: Bool = false
    public var enabled: Bool = false
    
    public lazy var appearanceProvider: LockAppearanceContentProvider = DefaultLockAppearanceProvider()
    
    
    public init(lock: Lock) {
        self.lock = lock
        observeApplicationLifeCycle()
    }
    
    private func observeApplicationLifeCycle() {
        notificationCenter.addObserver(self, selector: #selector(applicationDidEnterBackground), name:UIApplicationDidEnterBackgroundNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(applicationDidFinishLaunching), name:UIApplicationDidFinishLaunchingNotification, object: nil)
    }
    
    private func removeApplicationLifeCycle() {
        notificationCenter.removeObserver(self)
    }
    
    public func lockIfNeeded() {
        if !lock.havePasscode || locked || !enabled { return }
        lockContent()
    }
    
    public func unlockWithType(type: UnLockType, resultHandler: UnlockResultHandler? = nil) {
        if !lock.havePasscode {
            unlockContent()
            resultHandler?(.Success)
            return
        }
        
        lock.unlockWithType(type) { result in
            switch result {
                case .Success:
                    self.unlockContent()
                default:
                    break
            }
            resultHandler?(result)
        }
    }
    
    private func unlockContent() {
        splashViewController?.dismissViewControllerAnimated(true) { [weak self] _ in
            self?.locked = false
        }
    }
    
    private func lockContent() {
        let splashController = appearanceProvider.splashScreenViewControllerForLockHandler(self)
        let splashSnapshot = splashController.view.snapshotViewAfterScreenUpdates(true)
        
        if let mainWindow = UIApplication.sharedApplication().windows.first,
               topMostController = mainWindow.rootViewController?.topMostController {
            splashController.view.backgroundColor = .greenColor()
            
            splashSnapshot.frame = mainWindow.bounds
            mainWindow.addSubview(splashSnapshot)
            
            topMostController.presentViewController(splashController, animated: false) { [weak self, weak splashController] _ in
                splashSnapshot.removeFromSuperview()
                self?.splashViewController = splashController
                self?.locked = true
            }
        }
    }
    
    // MARK: - Application Life Cycle handler
    @objc private func applicationDidEnterBackground() {
        lockIfNeeded()
    }
    
    @objc private func applicationDidFinishLaunching() {
        lockIfNeeded()
    }
    
    deinit {
        unlockContent()
        removeApplicationLifeCycle()
    }
}

public protocol PasscodeImageSource: class {
    func passcodeField(sender: PasscodeField, dotImageAtIndex index: Int, filled: Bool) -> UIImage
}

public class PasscodeField: UIControl, UIKeyInput {
    
    public override var frame: CGRect {
        didSet {
            setNeedsDisplay()
        }
    }
    
    public override var tintColor: UIColor! {
        didSet {
            setNeedsDisplay()
        }
    }
    
    @IBInspectable
    public var passcode: String {
        get {
            return mutablePasscode
        } set {
            mutablePasscode = String(newValue.characters.dropFirst(maximumLength))
            setNeedsDisplay()
        }
    }
    
    @IBInspectable
    public var maximumLength: Int = 7 {
        didSet {
            setNeedsDisplay()
        }
    }
    
    @IBInspectable
    public var dotSize: CGSize = CGSize(width: 18, height: 18) {
        didSet {
            setNeedsDisplay()
        }
    }
    
    @IBInspectable
    public var dotSpacing: CGFloat = 25 {
        didSet {
            setNeedsDisplay()
        }
    }
    
    @IBInspectable
    public var lineHeight: CGFloat = 3 {
        didSet {
            setNeedsDisplay()
        }
    }
    
    public weak var dotImageSource: PasscodeImageSource? {
        didSet {
            setNeedsDisplay()
        }
    }
    
    public var autocapitalizationType: UITextAutocapitalizationType = .None
    public var autocorrectionType: UITextAutocorrectionType = .No
    public var spellCheckingType: UITextSpellCheckingType = .No
    public var enablesReturnKeyAutomatically: Bool = true
    public var keyboardAppearance: UIKeyboardAppearance = .Default
    public var returnKeyType: UIReturnKeyType = .Done
    public var keyboardType: UIKeyboardType = .NumberPad
    
    private var mutablePasscode: String = ""
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }
    
    private func commonInit() {
        addTarget(self, action: #selector(becomeFirstResponder), forControlEvents: .TouchUpInside)
    }
    
    // MARK: - UIKeyInput implementation
    public func hasText() -> Bool {
        return !mutablePasscode.isEmpty
    }
    
    public func insertText(text: String) {
        if !enabled || text.isEmpty { return }
        
        let newLength = mutablePasscode.characters.count + text.characters.count
        if newLength > Int(maximumLength) { return }
        
        mutablePasscode.appendContentsOf(text)
        setNeedsDisplay()
        sendActionsForControlEvents(.ValueChanged)
    }
    
    public func deleteBackward() {
        if !enabled || mutablePasscode.isEmpty { return }
        mutablePasscode = String(mutablePasscode.characters.dropLast())
        setNeedsDisplay()
        sendActionsForControlEvents(.ValueChanged)
    }
    
    public override func drawRect(rect: CGRect) {
        let originX = floorf(Float((rect.size.width - intrinsicContentSize().width)) * 0.5)
        let originY = floorf(Float((rect.size.height - intrinsicContentSize().height)) * 0.5)
        var origin = CGPoint(x: CGFloat(originX), y: CGFloat(originY))
        
        if let imageSource = dotImageSource {
            (0..<maximumLength).forEach { index in
                let unFilledImage = imageSource.passcodeField(self, dotImageAtIndex: index, filled: false)
                let filledImage = imageSource.passcodeField(self, dotImageAtIndex: index, filled: true)
                
                let image: UIImage
                if index < mutablePasscode.characters.count {
                    // draw filled image
                    image = filledImage
                } else {
                    // draw blank image
                    image = unFilledImage
                }
                let imageFrame = CGRect(x: origin.x, y: origin.y, width: dotSize.width, height: dotSize.height)
                image.drawInRect(imageFrame)
                
                origin.x += dotSize.width + dotSpacing
            }
        } else {
            let context = UIGraphicsGetCurrentContext()
            let fillColor: UIColor = tintColor ?? .blackColor()
            CGContextSetFillColorWithColor(context, fillColor.CGColor)
            
            (0..<maximumLength).forEach { index in
                if index < mutablePasscode.characters.count {
                    // draw circle
                    let circleFrame = CGRect(x: origin.x, y: origin.y, width: dotSize.width, height: dotSize.height)
                    CGContextFillEllipseInRect(context, circleFrame)
                } else {
                    // draw line
                    let lineFrame = CGRect(x: origin.x, y: origin.y + CGFloat(floorf(Float((dotSize.height - lineHeight) * 0.5))), width: dotSize.width, height: lineHeight)
                    CGContextFillRect(context, lineFrame)
                }
                origin.x += dotSize.width + dotSpacing
            }
        }
    }
    
    public override func intrinsicContentSize() -> CGSize {
        let totalSpacing = CGFloat(maximumLength - 1) * dotSpacing
        return CGSize(width: CGFloat(maximumLength) * dotSize.width + totalSpacing, height: dotSize.height)
    }
    
    public override func sizeThatFits(size: CGSize) -> CGSize {
        return intrinsicContentSize()
    }
    
    public override func canBecomeFirstResponder() -> Bool {
        return true
    }
}