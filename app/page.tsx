import { createRoomAction, joinRoomAction } from "./actions";

const DECK_MODES: ReadonlyArray<{
  value: string;
  label: string;
  emoji: string;
  short: string;
  detail: string;
}> = [
  {
    value: "classic",
    label: "Clásico",
    emoji: "🎲",
    short: "max(5, jugadores+1) de cada regla",
    detail: "Mazo grande y equilibrado.",
  },
  {
    value: "single",
    label: "Solo 1",
    emoji: "🎯",
    short: "1 copia de cada tipo",
    detail: "12 cartas en total. Cada regla aparece a lo sumo una vez.",
  },
  {
    value: "negative",
    label: "Negativos",
    emoji: "📉",
    short: "3 de cada + 6 de las que restan",
    detail: "Más cartas de subtract / sub_right / sub_left.",
  },
  {
    value: "positive",
    label: "Positivos",
    emoji: "📈",
    short: "3 de cada + solo 1 de las que restan",
    detail: "Mazo más amable: pocas cartas que quitan puntos.",
  },
  {
    value: "pairs",
    label: "Pares",
    emoji: "👯",
    short: "2 copias de cada regla",
    detail: "24 cartas en total. Mazo compacto y simétrico.",
  },
];

export default function Home() {
  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-10 px-6 py-16">
      <header className="text-center">
        <h1 className="font-display text-6xl tracking-tight">🐱 Michudice</h1>
        <p className="mt-3 text-white/70">
          Cartas, escaleras y un gato líder. 3-9 jugadores.
        </p>
      </header>

      <form
        action={createRoomAction}
        className="rounded-2xl bg-white/5 p-6 ring-1 ring-white/10"
      >
        <h2 className="mb-4 text-lg font-semibold">Crear sala</h2>

        <label className="mb-2 block text-sm text-white/70">Tu nombre</label>
        <input
          name="name"
          required
          maxLength={24}
          className="mb-5 w-full rounded-md bg-black/30 px-3 py-2 outline-none ring-1 ring-white/10 focus:ring-white/40"
          placeholder="Gabriel"
        />

        <p className="mb-2 text-sm text-white/70">Modo del mazo de reglas</p>
        <div className="mb-5 grid grid-cols-2 gap-2 sm:grid-cols-3">
          {DECK_MODES.map((m) => (
            <label key={m.value} className="cursor-pointer">
              <input
                type="radio"
                name="deck_mode"
                value={m.value}
                defaultChecked={m.value === "classic"}
                className="peer sr-only"
              />
              <div
                className={
                  "flex h-full flex-col gap-1 rounded-xl bg-black/20 p-3 ring-1 ring-white/10 transition " +
                  "hover:bg-white/5 " +
                  "peer-checked:bg-emerald-400/15 peer-checked:ring-2 peer-checked:ring-emerald-300 " +
                  "peer-focus-visible:ring-2 peer-focus-visible:ring-white/60"
                }
              >
                <div className="flex items-center gap-2">
                  <span className="text-xl">{m.emoji}</span>
                  <span className="font-semibold">{m.label}</span>
                </div>
                <p className="text-xs text-white/70">{m.short}</p>
                <p className="text-[11px] text-white/45">{m.detail}</p>
              </div>
            </label>
          ))}
        </div>

        <button
          type="submit"
          className="w-full rounded-md bg-emerald-500 px-4 py-2 font-semibold text-black hover:bg-emerald-400"
        >
          Crear partida
        </button>
      </form>

      <form
        action={joinRoomAction}
        className="rounded-2xl bg-white/5 p-6 ring-1 ring-white/10"
      >
        <h2 className="mb-4 text-lg font-semibold">Unirse a sala</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label className="mb-2 block text-sm text-white/70">Tu nombre</label>
            <input
              name="name"
              required
              maxLength={24}
              className="w-full rounded-md bg-black/30 px-3 py-2 outline-none ring-1 ring-white/10 focus:ring-white/40"
              placeholder="Gabriel"
            />
          </div>
          <div>
            <label className="mb-2 block text-sm text-white/70">Código</label>
            <input
              name="code"
              required
              maxLength={8}
              className="w-full rounded-md bg-black/30 px-3 py-2 uppercase tracking-widest outline-none ring-1 ring-white/10 focus:ring-white/40"
              placeholder="ABC123"
            />
          </div>
        </div>
        <button
          type="submit"
          className="mt-4 w-full rounded-md bg-amber-400 px-4 py-2 font-semibold text-black hover:bg-amber-300"
        >
          Entrar
        </button>
      </form>

      <footer className="text-center text-xs text-white/40">
        Reglas: cartas 3-9, repetidas se cancelan, escaleras de 3+ premian a la
        carta más baja, todos los jugadores deben ser Michudice 2 veces.
      </footer>
    </main>
  );
}
