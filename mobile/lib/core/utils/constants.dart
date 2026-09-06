/// Backend'e ulaşılamadığında (offline-first mod) kullanılan sahte rota kimliği.
/// Bu kimlikle işaretlenen rotalar hiçbir zaman backend'e senkronize edilmez;
/// tamamen cihaz üzerinde (local geofence) takip edilir.
const int kOfflineRouteId = 9999;
