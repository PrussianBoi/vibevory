import Foundation

/// Why the gateway keeps refusing the socket, told apart so the app can say so instead of counting attempts. A gateway
/// behind a Cloudflare Tunnel stayed on "Reconnecting" until the app was quit (#423): a Cloudflare error page or
/// sign-in page answered every attempt, and nothing said so. The socket keeps trying meanwhile. A sign-in Vory can do
/// itself is `SocketState.authRejected`, never one of these.
public enum ConnectProblem: Sendable, Equatable {
    /// Cloudflare answered for the gateway's address but could not reach the gateway (its 520 to 530 pages: the
    /// tunnel or the gateway behind it is down).
    case cloudflareOrigin(status: Int)
    /// Cloudflare Access asked for a sign-in in a browser, which Vory cannot do (it sends service-token headers only).
    case cloudflareSignIn
    /// A web page answered instead of the gateway (a Wi-Fi sign-in, a proxy, the wrong address).
    case webPage(status: Int)
    /// The address answered with an HTTP error instead of connecting.
    case http(status: Int)
    /// Nothing came back in time.
    case noAnswer

    /// A few words, where the connection's state is shown.
    public var title: String {
        switch self {
        case .cloudflareOrigin: return "Cloudflare can't reach the gateway"
        case .cloudflareSignIn: return "Cloudflare wants a sign-in"
        case .webPage: return "A web page answered, not the gateway"
        case .http(let status): return "The gateway answered HTTP \(status)"
        case .noAnswer: return "The gateway isn't answering"
        }
    }

    /// What it means and what to do, where there is room for a sentence or two.
    public var detail: String {
        switch self {
        case .cloudflareOrigin(let status):
            return "Cloudflare answered for the gateway's address but couldn't reach the gateway behind it (error \(status)). Check that the gateway and its tunnel (cloudflared) are running. Artha keeps trying."
        case .cloudflareSignIn:
            return "Cloudflare Access asked for a sign-in in a browser, which Artha can't do. Check the tunnel's Access settings, or add an Access service token to this gateway in Artha. Artha keeps trying."
        case .webPage(let status):
            return "Something between you and the gateway answered with a web page (HTTP \(status)): a Wi-Fi sign-in, a proxy, or the wrong address. Artha keeps trying."
        case .http(let status):
            return "The gateway's address answered with HTTP \(status) instead of connecting. Artha keeps trying."
        case .noAnswer:
            return "Nothing came back from the gateway's address. Artha keeps trying, and tries again at once when the network changes."
        }
    }

    /// Whether `location` (a redirect's target, or the address a redirect ended at) is Cloudflare Access's sign-in:
    /// its `/cdn-cgi/access/` paths, or a team's `cloudflareaccess.com` domain.
    public static func isAccessSignIn(_ location: String?) -> Bool {
        guard let l = location?.lowercased() else { return false }
        return l.contains("/cdn-cgi/access/") || l.contains(".cloudflareaccess.com")
    }

    /// The problem an attempt's error shows, or nil for one that says nothing in particular (cancelled, not
    /// connected yet).
    public static func of(_ error: Error) -> ConnectProblem? {
        switch error {
        case let e as SocketError:
            switch e {
            case .refused(let status, let location, let cloudflare, let html):
                if isAccessSignIn(location) { return .cloudflareSignIn }
                if (520...530).contains(status) { return cloudflare ? .cloudflareOrigin(status: status) : .http(status: status) }
                if cloudflare, status == 401 || status == 403 { return .cloudflareSignIn }
                if html || (300..<400).contains(status) || status == 200 { return .webPage(status: status) }
                return .http(status: status)
            case .timeout: return .noAnswer
            case .closed(let code, _): return code == 4401 || code == 4403 ? nil : .noAnswer
            case .notConnected, .cancelled: return nil
            }
        case let e as HermesAPIError:
            switch e {
            case .cloudflareAccess: return .cloudflareSignIn
            case .htmlResponse(let status): return (520...530).contains(status) ? .cloudflareOrigin(status: status) : .webPage(status: status)
            case .http(let status, _): return .http(status: status)
            case .transport: return .noAnswer
            case .unauthorized, .sessionExpired, .decoding: return nil
            }
        case let e as URLError:
            switch e.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                return .noAnswer
            default: return nil
            }
        default:
            return nil
        }
    }
}
