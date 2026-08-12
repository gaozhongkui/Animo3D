//
//  ImageLoader.swift
//  Animo3D
//

import UIKit

final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()

    func loadImage(from urlString: String, completion: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        if let cachedImage = cache.object(forKey: urlString as NSString) {
            completion(cachedImage)
            return nil
        }

        guard let url = URL(string: urlString) else {
            completion(nil)
            return nil
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data, let image = UIImage(data: data), error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self?.cache.setObject(image, forKey: urlString as NSString)
            DispatchQueue.main.async { completion(image) }
        }
        task.resume()
        return task
    }
}
