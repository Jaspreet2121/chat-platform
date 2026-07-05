"use client";

import "leaflet/dist/leaflet.css";
import L from "leaflet";
import { useEffect, useMemo } from "react";
import { MapContainer, Marker, TileLayer, useMap } from "react-leaflet";

export type LeafletMapProps = {
  lat: number;
  lng: number;
  /** Live = a pulsing green marker; otherwise a static brand-colored pin. */
  live?: boolean;
  /** Map height in px (width fills the container). */
  height?: number;
  /** Allow pan/zoom gestures. */
  interactive?: boolean;
  zoom?: number;
};

// Themed marker built with L.divIcon (inline SVG/HTML) instead of Leaflet's default PNG marker — this
// sidesteps the well-known bundler issue where leaflet's marker-icon.png / marker-shadow.png asset paths
// break under webpack/Next. No image assets, fully themeable, and a pulsing ring while live.
function pinIcon(live: boolean): L.DivIcon {
  const color = live ? "#22c55e" : "#4E63C8";
  const pulse = live
    ? `<span class="ll-pulse" style="--ll-pulse:${color}"></span>`
    : "";
  const html = `
    <span class="ll-pin-wrap">
      ${pulse}
      <svg width="26" height="34" viewBox="0 0 24 32" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        <path d="M12 0C5.37 0 0 5.37 0 12c0 8.4 12 20 12 20s12-11.6 12-20C24 5.37 18.63 0 12 0z" fill="${color}"/>
        <circle cx="12" cy="12" r="4.5" fill="#fff"/>
      </svg>
    </span>`;

  return L.divIcon({
    html,
    className: "ll-pin",
    iconSize: [26, 34],
    iconAnchor: [13, 33]
  });
}

// Smoothly re-center the map when the coordinate changes (the "advanced" live feel — the marker slides
// into view as the peer moves). Keeps the user's current zoom.
function Recenter({ lat, lng }: { lat: number; lng: number }) {
  const map = useMap();
  useEffect(() => {
    map.setView([lat, lng], map.getZoom(), { animate: true });
  }, [lat, lng, map]);
  return null;
}

export default function LeafletMap({
  lat,
  lng,
  live = false,
  height = 150,
  interactive = true,
  zoom = 15
}: LeafletMapProps) {
  const icon = useMemo(() => pinIcon(live), [live]);

  return (
    <MapContainer
      center={[lat, lng]}
      zoom={zoom}
      zoomControl={false}
      scrollWheelZoom={false}
      dragging={interactive}
      doubleClickZoom={interactive}
      touchZoom={interactive}
      boxZoom={false}
      keyboard={false}
      attributionControl
      className="ll-container"
      style={{ height, width: "100%" }}
    >
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
        url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
      />
      <Marker position={[lat, lng]} icon={icon} />
      <Recenter lat={lat} lng={lng} />
    </MapContainer>
  );
}
