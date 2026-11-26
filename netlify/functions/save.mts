// Spielstand eines angemeldeten Kontos laden (GET) oder speichern (PUT).
// Anmeldung: Netlify Identity. Der Zugriffstoken wird bei Identity selbst
// geprüft; gespeichert wird nur unter der ID des geprüften Kontos.
import { getStore } from "@netlify/blobs";
import type { Config } from "@netlify/functions";

const MAX_BYTES = 1_500_000;

function store() {
  // Region bei JEDEM Aufruf gleich angeben, sonst landet man im leeren Standard-Speicher
  return getStore({ name: "spielstaende", region: "eu-central-1", consistency: "strong" });
}

async function currentUser(req: Request): Promise<{ id: string; email?: string } | null> {
  const auth = req.headers.get("authorization");
  if (!auth || !auth.startsWith("Bearer ")) return null;
  const res = await fetch(new URL("/.netlify/identity/user", req.url), {
    headers: { authorization: auth },
  });
  if (!res.ok) return null;
  const user = (await res.json()) as { id?: string; email?: string };
  return user && typeof user.id === "string" ? { id: user.id, email: user.email } : null;
}

export default async (req: Request) => {
  const user = await currentUser(req);
  if (!user) return new Response("Nicht angemeldet", { status: 401 });

  if (req.method === "GET") {
    const save = await store().get(user.id, { type: "json" });
    return Response.json(save ?? null, { headers: { "cache-control": "no-store" } });
  }

  if (req.method === "PUT") {
    const text = await req.text();
    if (text.length > MAX_BYTES) return new Response("Spielstand zu groß", { status: 413 });
    let body: { updatedAt?: unknown; data?: unknown };
    try {
      body = JSON.parse(text);
    } catch {
      return new Response("Ungültiges JSON", { status: 400 });
    }
    if (typeof body.updatedAt !== "number" || typeof body.data !== "object" || body.data === null) {
      return new Response("Ungültiger Spielstand", { status: 400 });
    }
    await store().setJSON(user.id, { updatedAt: body.updatedAt, data: body.data });
    return Response.json({ ok: true, updatedAt: body.updatedAt });
  }

  return new Response("Methode nicht erlaubt", { status: 405 });
};

export const config: Config = { path: "/api/save" };
