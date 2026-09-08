import { createClient } from "jsr:@supabase/supabase-js@2";

const DEFAULT_THRESHOLDS = { far: 1000, mid: 500, near: 250 };
const MAX_THRESHOLD_M = 20000; // 20 km — makul bir üst sınır

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function getDeviceId(req: Request): string {
  return (req.headers.get("X-Device-Id") ?? "").trim();
}

function parseCoordinate(
  value: unknown,
  name: string,
  min: number,
  max: number,
): [number | null, string | null] {
  if (value === undefined || value === null) {
    return [null, `${name} alanı zorunludur.`];
  }
  const parsed = typeof value === "number" ? value : parseFloat(String(value));
  if (Number.isNaN(parsed)) {
    return [null, `${name} sayısal bir değer olmalıdır.`];
  }
  if (parsed < min || parsed > max) {
    return [null, `${name} ${min} ile ${max} arasında olmalıdır.`];
  }
  return [parsed, null];
}

function parseThresholds(
  data: Record<string, unknown>,
): [{ far: number; mid: number; near: number } | null, string | null] {
  const raw = {
    far: data.threshold_far_m,
    mid: data.threshold_mid_m,
    near: data.threshold_near_m,
  };
  const values = Object.values(raw);
  if (values.every((v) => v === undefined || v === null)) {
    return [DEFAULT_THRESHOLDS, null];
  }
  if (values.some((v) => v === undefined || v === null)) {
    return [
      null,
      "Eşik değerleri gönderiliyorsa threshold_far_m, threshold_mid_m ve threshold_near_m alanlarının hepsi zorunludur.",
    ];
  }

  const parsed: Record<string, number> = {};
  for (const [key, value] of Object.entries(raw)) {
    const num = Number(value);
    if (!Number.isInteger(num)) {
      return [null, `threshold_${key}_m tam sayı olmalıdır.`];
    }
    if (num <= 0 || num > MAX_THRESHOLD_M) {
      return [null, `threshold_${key}_m 0 ile ${MAX_THRESHOLD_M} arasında olmalıdır.`];
    }
    parsed[key] = num;
  }

  if (!(parsed.far > parsed.mid && parsed.mid > parsed.near)) {
    return [
      null,
      "Eşikler threshold_far_m > threshold_mid_m > threshold_near_m sıralamasında olmalıdır.",
    ];
  }

  return [parsed as { far: number; mid: number; near: number }, null];
}

function calculateDistance(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number,
): number {
  const R = 6371000.0;
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

function routeToJson(route: Record<string, any>, full = false) {
  const base: Record<string, unknown> = {
    id: route.id,
    destination_name: route.destination_name,
    dest_latitude: route.dest_latitude,
    dest_longitude: route.dest_longitude,
    status: route.status,
    is_muted: route.is_muted,
    created_at: route.created_at,
  };
  if (full) {
    base.threshold_far_m = route.threshold_far_m;
    base.threshold_mid_m = route.threshold_mid_m;
    base.threshold_near_m = route.threshold_near_m;
  }
  return base;
}

async function listRoutes(req: Request): Promise<Response> {
  const deviceId = getDeviceId(req);
  if (!deviceId) {
    return json({ error: "X-Device-Id başlığı zorunludur." }, 400);
  }

  const { data, error } = await supabase
    .from("target_route")
    .select("*")
    .eq("device_id", deviceId)
    .order("created_at", { ascending: false })
    .limit(50);

  if (error) {
    console.error("list_routes error", error);
    return json({ error: "Rotalar listelenirken beklenmeyen bir hata oluştu." }, 500);
  }

  return json(data.map((r) => routeToJson(r)), 200);
}

async function createRoute(req: Request): Promise<Response> {
  const deviceId = getDeviceId(req);
  if (!deviceId) {
    return json({ error: "X-Device-Id başlığı zorunludur." }, 400);
  }

  const body = await req.json().catch(() => ({}));

  const destinationName = body.destination_name;
  if (!destinationName || !String(destinationName).trim()) {
    return json({ error: "Lütfen destination_name alanını doldurun." }, 400);
  }

  const [destLat, latError] = parseCoordinate(body.dest_latitude, "dest_latitude", -90, 90);
  if (latError) return json({ error: latError }, 400);

  const [destLng, lngError] = parseCoordinate(body.dest_longitude, "dest_longitude", -180, 180);
  if (lngError) return json({ error: lngError }, 400);

  const [thresholds, thresholdError] = parseThresholds(body);
  if (thresholdError) return json({ error: thresholdError }, 400);

  try {
    // Aynı cihazın eski aktif rotalarını kapat (Aynı anda tek bir aktif rota takibi için).
    await supabase
      .from("target_route")
      .update({ status: "MUTED", is_muted: true })
      .eq("status", "ACTIVE")
      .eq("device_id", deviceId);

    const { data: route, error } = await supabase
      .from("target_route")
      .insert({
        device_id: deviceId,
        destination_name: destinationName,
        dest_latitude: destLat,
        dest_longitude: destLng,
        status: "ACTIVE",
        is_muted: false,
        threshold_far_m: thresholds!.far,
        threshold_mid_m: thresholds!.mid,
        threshold_near_m: thresholds!.near,
      })
      .select()
      .single();

    if (error) throw error;

    return json(routeToJson(route, true), 201);
  } catch (err) {
    console.error("create_route beklenmeyen bir hatayla karşılaştı.", err);
    return json({ error: "Rota oluşturulurken beklenmeyen bir hata oluştu." }, 500);
  }
}

async function getOwnedRoute(routeId: number, deviceId: string) {
  const { data: route, error } = await supabase
    .from("target_route")
    .select("*")
    .eq("id", routeId)
    .maybeSingle();

  if (error || !route) return { route: null, response: json({ error: "Bulunamadı." }, 404) };
  if (route.device_id !== deviceId) {
    return { route: null, response: json({ error: "Bu rotaya erişim yetkiniz yok." }, 403) };
  }
  return { route, response: null };
}

async function updateLocation(req: Request, routeId: number): Promise<Response> {
  const deviceId = getDeviceId(req);
  if (!deviceId) {
    return json({ error: "X-Device-Id başlığı zorunludur." }, 400);
  }

  const { route, response } = await getOwnedRoute(routeId, deviceId);
  if (response) return response;

  const body = await req.json().catch(() => ({}));

  const [currentLat, latError] = parseCoordinate(body.current_latitude, "current_latitude", -90, 90);
  if (latError) return json({ error: latError }, 400);

  const [currentLng, lngError] = parseCoordinate(body.current_longitude, "current_longitude", -180, 180);
  if (lngError) return json({ error: lngError }, 400);

  try {
    if (route!.is_muted || route!.status === "MUTED") {
      return json({
        route_id: route!.id,
        distance_meters: calculateDistance(currentLat!, currentLng!, route!.dest_latitude, route!.dest_longitude),
        status: "MUTED",
        is_muted: true,
        trigger_alarm: false,
        target_stage: "MUTED",
        message: "Takip susturulmuş durumda. Alarm tetiklenmeyecek.",
      }, 200);
    }

    const distance = calculateDistance(currentLat!, currentLng!, route!.dest_latitude, route!.dest_longitude);
    let triggerAlarm = false;
    let targetStage = "OUT_OF_RANGE";
    let message = "Hedef dışındasınız.";
    const updates: Record<string, unknown> = {};

    if (distance <= route!.threshold_near_m) {
      if (!route!.notified_250m) {
        updates.notified_250m = true;
        updates.notified_500m = true; // Bypass koruması
        updates.notified_1km = true; // Bypass koruması
        updates.status = "ARRIVED";

        triggerAlarm = true;
        targetStage = "STAGE_NEAR";
        message = `Hedefe ${route!.threshold_near_m} metre veya daha az mesafe kaldı! Yüksek öncelikli alarm çalınmalı.`;
      } else {
        targetStage = "STAGE_NEAR";
        message = "Yakın mesafe alarmı zaten tetiklendi.";
      }
    } else if (distance <= route!.threshold_mid_m) {
      if (!route!.notified_500m) {
        updates.notified_500m = true;
        updates.notified_1km = true; // Bypass koruması

        triggerAlarm = true;
        targetStage = "STAGE_MID";
        message = `Hedefe ${route!.threshold_mid_m} metre veya daha az mesafe kaldı! Bildirim/alarm tetiklenmeli.`;
      } else {
        targetStage = "STAGE_MID";
        message = "Orta mesafe alarmı zaten tetiklendi.";
      }
    } else if (distance <= route!.threshold_far_m) {
      if (!route!.notified_1km) {
        updates.notified_1km = true;

        triggerAlarm = true;
        targetStage = "STAGE_FAR";
        message = `Hedefe ${route!.threshold_far_m} metre veya daha az mesafe kaldı! Bildirim/alarm tetiklenmeli.`;
      } else {
        targetStage = "STAGE_FAR";
        message = "Uzak mesafe alarmı zaten tetiklendi.";
      }
    } else {
      message = `Hedefe ${Math.round(distance * 10) / 10} metre kaldı.`;
    }

    let finalStatus = route!.status;
    if (Object.keys(updates).length > 0) {
      const { data: updated, error } = await supabase
        .from("target_route")
        .update(updates)
        .eq("id", route!.id)
        .select()
        .single();
      if (error) throw error;
      finalStatus = updated.status;
    }

    return json({
      route_id: route!.id,
      distance_meters: Math.round(distance * 100) / 100,
      status: finalStatus,
      is_muted: route!.is_muted,
      trigger_alarm: triggerAlarm,
      target_stage: targetStage,
      message,
    }, 200);
  } catch (err) {
    console.error(`update_location beklenmeyen bir hatayla karşılaştı. route_id=${routeId}`, err);
    return json({ error: "Konum işlenirken beklenmeyen bir hata oluştu." }, 500);
  }
}

async function muteRoute(req: Request, routeId: number): Promise<Response> {
  const deviceId = getDeviceId(req);
  if (!deviceId) {
    return json({ error: "X-Device-Id başlığı zorunludur." }, 400);
  }

  const { route, response } = await getOwnedRoute(routeId, deviceId);
  if (response) return response;

  const { error } = await supabase
    .from("target_route")
    .update({ is_muted: true, status: "MUTED" })
    .eq("id", route!.id);

  if (error) {
    console.error("mute_route error", error);
    return json({ error: "Rota susturulurken beklenmeyen bir hata oluştu." }, 500);
  }

  return json({
    route_id: route!.id,
    status: "MUTED",
    is_muted: true,
    message: "Rota takibi susturuldu. Gelecek alarm tetiklemeleri tamamen kapatıldı.",
  }, 200);
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  // Beklenen path'ler: /routes  /routes/:id/update-location  /routes/:id/mute
  // (deploy'da prefix /functions/v1/routes/... şeklinde gelir)
  const segments = url.pathname.split("/").filter(Boolean);
  const routesIdx = segments.lastIndexOf("routes");
  const parts = routesIdx === -1 ? segments : segments.slice(routesIdx + 1);

  try {
    if (parts.length === 0) {
      if (req.method === "GET") return await listRoutes(req);
      if (req.method === "POST") return await createRoute(req);
      return json({ error: "Method not allowed." }, 405);
    }

    const routeId = Number(parts[0]);
    if (!Number.isInteger(routeId)) {
      return json({ error: "Geçersiz route id." }, 400);
    }

    const action = parts[1];
    if (action === "update-location" && req.method === "POST") {
      return await updateLocation(req, routeId);
    }
    if (action === "mute" && req.method === "POST") {
      return await muteRoute(req, routeId);
    }

    return json({ error: "Bulunamadı." }, 404);
  } catch (err) {
    console.error("Beklenmeyen hata", err);
    return json({ error: "Beklenmeyen bir hata oluştu." }, 500);
  }
});
