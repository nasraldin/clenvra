public import Darwin

/// Who may use the helper. It acts on folders shared by every user of the Mac, so only administrators, the same
/// people macOS lets change those folders with their password, may ask it to.
public enum HelperAuthorization {
    /// The `admin` group.
    static let adminGroupID: gid_t = 80

    public static func isAdministrator(uid: uid_t) -> Bool {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return false }
        let primaryGroup = entry.pointee.pw_gid
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        while getgrouplist(name, Int32(bitPattern: primaryGroup), &groups, &count) == -1 {
            guard count < 4_096 else { return false }
            count *= 2
            groups = [Int32](repeating: 0, count: Int(count))
        }
        return groups.prefix(Int(count)).contains(Int32(bitPattern: adminGroupID))
    }
}
