import SwiftUI
import Photos
import UIKit

struct PhotoStripView: View {
    let assetIDs: [String]
    @State private var images: [String: UIImage] = [:]
    @State private var fullScreenID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(assetIDs, id: \.self) { id in
                    Group {
                        if let image = images[id] {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color(.secondarySystemFill).overlay(ProgressView())
                        }
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { fullScreenID = id }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .task { await loadImages() }
        .fullScreenCover(item: Binding(
            get: { fullScreenID.map { IdentifiableString(value: $0) } },
            set: { fullScreenID = $0?.value }
        )) { item in
            PhotoViewerView(assetID: item.value)
        }
    }

    private func loadImages() async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        var assetList: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in assetList.append(asset) }

        for asset in assetList {
            let img: UIImage? = await withCheckedContinuation { continuation in
                manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 240, height: 240),
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                    if !isDegraded { continuation.resume(returning: image) }
                }
            }
            if let img { images[asset.localIdentifier] = img }
        }
    }
}

private struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}
