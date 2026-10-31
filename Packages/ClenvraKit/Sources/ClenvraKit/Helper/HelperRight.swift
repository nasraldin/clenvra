public import Foundation
import Security

/// The Authorization Services right the helper checks before it changes a Mac-wide startup item or permission.
///
/// The app sends only an empty authorization reference for its login session. The helper itself asks Authorization
/// Services for the right, which shows the password dialog in the person's session. The rule is never shared: an
/// approval lives only inside the one authorization the app makes for one action (one Uninstall, one Disable of
/// several items), for at most five minutes, and the app destroys it when the action ends; so each action asks for
/// an administrator's password once, and the next action asks again.
public enum HelperRight {
    public static let name = HelperIdentity.helperIdentifier + ".change-system-settings"

    /// An administrator's password, once per action.
    public static var definition: [String: Any] {
        [
            "class": "user", "group": "admin", "authenticate-user": true, "shared": false, "timeout": 300,
            "allow-root": false, "session-owner": false, "version": 1,
            "comment": "Clenvra changes a startup item or a permission for every user of this Mac.",
        ]
    }

    // MARK: - App side

    /// An empty authorization for this login session and its external form, to send to the helper. The reference
    /// must stay alive until the helper has answered; free it with `AuthorizationFree`.
    static func makeClientAuthorization() -> (reference: AuthorizationRef, externalForm: Data)? {
        var created: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &created) == errAuthorizationSuccess, let reference = created else {
            return nil
        }
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else {
            AuthorizationFree(reference, [])
            return nil
        }
        return (reference, withUnsafeBytes(of: &external) { Data($0) })
    }

    // MARK: - Helper side

    /// Adds the right to the authorization database, or puts it back when the rule there is not exactly ours (an
    /// older version, or one planted as "allow"). Run by the helper as root.
    public static func install() {
        if isInstalledAsDefined() { return }
        var created: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &created) == errAuthorizationSuccess, let reference = created else {
            return
        }
        defer { AuthorizationFree(reference, []) }
        _ = AuthorizationRightSet(reference, name, definition as CFDictionary, nil, nil, nil)
    }

    /// Whether the rule in the database is exactly ours. Anyone may add a missing right, so a right planted as
    /// "allow" before the helper installed it must never be trusted.
    static func isInstalledAsDefined() -> Bool {
        var current: CFDictionary?
        guard AuthorizationRightGet(name, &current) == errAuthorizationSuccess,
            let rule = current as? [String: Any]
        else { return false }
        return rule["class"] as? String == "user" && rule["group"] as? String == "admin"
            && rule["authenticate-user"] as? Bool == true && rule["shared"] as? Bool == false
            && rule["timeout"] as? Int == 300 && rule["allow-root"] as? Bool != true
            && rule["session-owner"] as? Bool != true
    }

    /// Asks for an administrator's password in the session of the app that sent `externalForm`. `true` only when
    /// it was given just now.
    public static func authorize(_ externalForm: Data?) -> Bool {
        guard isInstalledAsDefined(), let externalForm,
            externalForm.count == MemoryLayout<AuthorizationExternalForm>.size
        else { return false }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { externalForm.copyBytes(to: $0) }
        var created: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &created) == errAuthorizationSuccess,
            let reference = created
        else { return false }
        // Not .destroyRights: the approval belongs to the app's authorization, which the app destroys when its action
        // ends; destroying it here would ask again for every step of one action.
        defer { AuthorizationFree(reference, []) }
        return name.withCString { pointer in
            var item = AuthorizationItem(name: pointer, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                return AuthorizationCopyRights(reference, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }
    }
}
