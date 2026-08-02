import AppKit
import Foundation
import Network
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "LocalNetworkAccess"
)

/// Nudges macOS into offering its "Local Network" privacy permission for Ghostty.
///
/// A process we exec into the pty inherits Ghostty as its TCC "responsible
/// process", so it is Ghostty that has to hold the local network permission on
/// behalf of everything the user runs in the terminal. But Ghostty itself never
/// touches the local network, so as of macOS 26 the system has no reason to ever
/// ask for that permission: the request is denied by default, connections to LAN
/// addresses made from the shell fail with EHOSTUNREACH while the internet at
/// large keeps working, and Ghostty doesn't even appear under System Settings ->
/// Privacy & Security -> Local Network for the user to fix it by hand.
///
/// Reaching for the local network from the app process is what gives the system
/// something to prompt about. Once the user allows it the shell is covered too,
/// because the shell is Ghostty's responsibility.
///
/// This only ever runs from an explicit user action, never on launch: we don't
/// want to put packets on someone's network behind their back, and this only
/// needs to happen once.
@MainActor
class LocalNetworkAccess {
    static let shared = LocalNetworkAccess()

    /// The Bonjour service type we browse for. Browsing is the documented way to
    /// ask for local network access and the type barely matters, but SSH is at
    /// least a plausible thing for a terminal to go looking for. This has to be
    /// listed in NSBonjourServices or the browse is rejected before it starts.
    private static let serviceType = "_ssh._tcp"

    /// How long the Bonjour browse runs for. The system prompt outlives this, so
    /// it isn't a deadline for the user to answer in.
    private static let browseDuration: DispatchTimeInterval = .seconds(3)

    /// Queue for the socket probes, which can block briefly on ARP resolution.
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.local-network")

    private var browser: NWBrowser?

    /// Reach for the local network so that macOS shows its permission prompt.
    /// Returns as soon as the probes are underway; they tear themselves down.
    func request() {
        browse()
        queue.async { LocalNetworkProbe.run() }
    }

    /// Open System Settings on the Local Network privacy pane, so the user can
    /// check or flip the switch by hand.
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Browse for a Bonjour service on the local domain. This is the trigger
    /// Apple documents for local network access.
    private func browse() {
        browser?.cancel()

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: "local."),
            using: .tcp)
        browser.stateUpdateHandler = { state in
            logger.info("bonjour browser state=\(String(describing: state), privacy: .public)")
        }
        self.browser = browser
        browser.start(queue: .main)

        // We don't care about the results, only about having asked, so stop
        // once the system has had a chance to notice.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.browseDuration) { [weak self] in
            MainActor.assumeIsolated {
                browser.cancel()
                if self?.browser === browser { self?.browser = nil }
            }
        }
    }
}

/// The raw socket half of ``LocalNetworkAccess``.
///
/// Bonjour alone should be enough to get us prompted, but sending a datagram at
/// a LAN address is the exact thing that fails for the user when they run `ping`
/// in the shell, so it's the most faithful trigger we have.
private enum LocalNetworkProbe {
    /// Discard protocol (RFC 863). Nothing is expected to answer; all that
    /// matters is that the datagrams are addressed at the local network.
    private static let port: UInt16 = 9

    /// Send a datagram at every subnet we're attached to.
    static func run() {
        let targets = targets()
        guard !targets.isEmpty else {
            logger.warning("no local IPv4 subnets to probe")
            return
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            logger.warning("failed to open probe socket errno=\(errno)")
            return
        }
        defer { close(fd) }

        // Needed for the subnet broadcast addresses below.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        for target in targets {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: target.bigEndian)

            var payload: UInt8 = 0
            let sent = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, &payload, 1, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            // A failure here is the whole point: we expect EHOSTUNREACH until
            // the permission is granted. It's the only signal we get, so log
            // it either way.
            if sent < 0 {
                logger.info("probe \(describe(target), privacy: .public) failed errno=\(errno)")
            } else {
                logger.info("probe \(describe(target), privacy: .public) sent")
            }
        }
    }

    /// Addresses on our directly attached IPv4 subnets, in host byte order: for
    /// each one the subnet broadcast address and the first host address, which
    /// is conventionally the router.
    private static func targets() -> [UInt32] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var targets: [UInt32] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0
            else { continue }

            guard let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  let nm = ifa.pointee.ifa_netmask
            else { continue }

            let addr = UInt32(bigEndian: sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            })
            let mask = UInt32(bigEndian: nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            })

            // A host route has no subnet to probe, and a self-assigned
            // 169.254/16 address means nothing answered DHCP, so there's
            // unlikely to be anyone out there to reach.
            guard mask != .max, addr & 0xFFFF_0000 != 0xA9FE_0000 else { continue }

            let network = addr & mask
            for candidate in [network | ~mask, network | 1] where candidate != addr {
                if !targets.contains(candidate) { targets.append(candidate) }
            }
        }

        return targets
    }

    private static func describe(_ addr: UInt32) -> String {
        "\(addr >> 24 & 0xFF).\(addr >> 16 & 0xFF).\(addr >> 8 & 0xFF).\(addr & 0xFF)"
    }
}
