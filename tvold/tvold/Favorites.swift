import Foundation

// Favourites are stored whole rather than as references into the index, so
// the favourites list opens without parsing any country file.
final class Favorites {
    static let shared = Favorites()

    private let key = "tvold.favorites"
    private(set) var channels: [Channel] = []
    private var urls = Set<String>()

    private init() {
        let raw = (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? []
        for item in raw {
            if let c = Channel(json: item) {
                channels.append(c)
                urls.insert(c.url)
            }
        }
    }

    func contains(_ c: Channel) -> Bool {
        return urls.contains(c.url)
    }

    func toggle(_ c: Channel) {
        if urls.contains(c.url) {
            urls.remove(c.url)
            channels = channels.filter { $0.url != c.url }
        } else {
            urls.insert(c.url)
            channels.append(c)
        }
        UserDefaults.standard.set(channels.map { $0.json }, forKey: key)
        UserDefaults.standard.synchronize()
    }
}
