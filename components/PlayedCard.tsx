"use client";

interface Props {
  /** Valor de la carta. null = el jugador todavía no eligió. */
  value: number | null;
  /** Si true, voltea la carta para mostrar su valor. */
  revealed: boolean;
}

/**
 * Carta jugada por un jugador. Tiene tres estados visuales:
 *  - sin elección → slot punteado vacío
 *  - elegida pero no revelada → carta boca abajo (Michudice)
 *  - revelada → flip 3D mostrando el valor
 */
export default function PlayedCard({ value, revealed }: Props) {
  if (value === null) return <div className="card-slot" aria-label="esperando" />;
  return (
    <div
      className={"flip-card " + (revealed ? "is-flipped" : "")}
      aria-label={revealed ? `carta ${value}` : "carta boca abajo"}
    >
      <div className="flip-inner">
        <div className="flip-face flip-front" aria-hidden="true" />
        <div className="flip-face flip-back">{value}</div>
      </div>
    </div>
  );
}
