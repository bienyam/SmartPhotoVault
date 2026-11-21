import MapKit
import SwiftUI

/// Pick an area on the map for the Archive place filter. Photo locations stay on this iPhone;
/// only the map itself is loaded from Apple Maps.
struct PlacePickerSheet: View {
    @Binding var place: PlaceArea?
    let snapshot: ScanSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion?

    /// One dot per rounded spot (about 1 km), capped so the map stays quick.
    private var spots: [CLLocationCoordinate2D] {
        var seen = Set<String>()
        var result: [CLLocationCoordinate2D] = []
        for record in snapshot.assets {
            guard let latitude = record.latitude, let longitude = record.longitude else { continue }
            guard seen.insert("\(latitude),\(longitude)").inserted else { continue }
            result.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            if result.count == 500 { break }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                    Annotation("", coordinate: spot) {
                        Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in region = context.region }
            .safeAreaInset(edge: .bottom) {
                Text("Move and zoom the map. Photos taken inside the visible area will match.")
                    .font(.footnote)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
            .navigationTitle("Choose a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this area") {
                        if let region { place = Self.area(for: region) }
                        dismiss()
                    }
                    .disabled(region == nil)
                }
            }
        }
    }

    static func area(for region: MKCoordinateRegion) -> PlaceArea {
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        return PlaceArea(minLatitude: region.center.latitude - halfLat, maxLatitude: region.center.latitude + halfLat,
                         minLongitude: region.center.longitude - halfLon, maxLongitude: region.center.longitude + halfLon)
    }
}
