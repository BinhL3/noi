import mark from "../../assets/noi-mark.svg";

/** The brand name is not UI copy; it is never translated. */
const BRAND = "Noi";

/**
 * The Noi wordmark: the wave mark followed by the name in the system face.
 * The mark keeps its own soft blues; the text inherits `currentColor`.
 */
const NoiWordmark = ({
  width = 120,
  className,
}: {
  width?: number;
  className?: string;
}) => {
  // The mark's artwork has generous padding; size it so the visible wave
  // matches the cap height of the text.
  const markSize = Math.round(width * 0.42);
  const fontSize = Math.round(width * 0.24);
  return (
    <div
      className={`inline-flex items-center gap-1 select-none ${className ?? ""}`}
      style={{ width }}
      role="img"
      aria-label={BRAND}
    >
      <img
        src={mark}
        alt=""
        width={markSize}
        height={markSize}
        style={{ marginLeft: -markSize * 0.18 }}
        draggable={false}
      />
      <span
        className="font-bold tracking-tight"
        style={{ fontSize, lineHeight: 1 }}
      >
        {BRAND}
      </span>
    </div>
  );
};

export default NoiWordmark;
