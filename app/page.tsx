import { createRoomAction, joinRoomAction } from "./actions";

export default function Home() {
  return (
    <main className="mx-auto flex max-w-2xl flex-col gap-10 px-6 py-16">
      <header className="text-center">
        <h1 className="font-display text-6xl tracking-tight">🐱 Michudice</h1>
        <p className="mt-3 text-white/70">
          Cartas, escaleras y un gato líder. 3-9 jugadores.
        </p>
      </header>

      <section className="grid gap-6 sm:grid-cols-2">
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
            className="mb-4 w-full rounded-md bg-black/30 px-3 py-2 outline-none ring-1 ring-white/10 focus:ring-white/40"
            placeholder="Gabriel"
          />
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
          <label className="mb-2 block text-sm text-white/70">Tu nombre</label>
          <input
            name="name"
            required
            maxLength={24}
            className="mb-4 w-full rounded-md bg-black/30 px-3 py-2 outline-none ring-1 ring-white/10 focus:ring-white/40"
            placeholder="Gabriel"
          />
          <label className="mb-2 block text-sm text-white/70">Código</label>
          <input
            name="code"
            required
            maxLength={8}
            className="mb-4 w-full rounded-md bg-black/30 px-3 py-2 uppercase tracking-widest outline-none ring-1 ring-white/10 focus:ring-white/40"
            placeholder="ABC123"
          />
          <button
            type="submit"
            className="w-full rounded-md bg-amber-400 px-4 py-2 font-semibold text-black hover:bg-amber-300"
          >
            Entrar
          </button>
        </form>
      </section>

      <footer className="text-center text-xs text-white/40">
        Reglas: cartas 3-9, repetidas se cancelan, escaleras de 3+ premian a la
        carta más baja, todos los jugadores deben ser Michudice 2 veces.
      </footer>
    </main>
  );
}
