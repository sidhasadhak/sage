import SwiftUI
import Photos
import UIKit

struct PhotoViewerView: View {
    let assetID: String
    @State private var image: UIImage?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
        .task { await loadImage() }
    }

    private func loadImage() async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        image = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit, options: options
            ) { img, _ in continuation.resume(returning: img) }
        }
    }
}
