/**
 * The Noi wordmark: an island glyph — the notch pill it lives in — followed by
 * the name in the system face. Inherits `currentColor` so it sits on glass in
 * either theme.
 */
/** The brand name is not UI copy; it is never translated. */
const BRAND = "Noi";

const NoiWordmark = ({
  width = 120,
  className,
}: {
  width?: number;
  className?: string;
}) => (
  <svg
    viewBox="0 0 120 40"
    width={width}
    height={(width * 40) / 120}
    className={className}
    role="img"
    aria-label="Noi"
    fill="currentColor"
  >
    {/* Island: a pill with concave top flares, as on the screen. */}
    <path d="M2 4 Q8 4 8 10 V20 A6 6 0 0 0 14 26 H32 A6 6 0 0 0 38 20 V10 Q38 4 44 4 Z" />
    <text
      x="52"
      y="29"
      fontFamily="-apple-system, BlinkMacSystemFont, 'SF Pro Display', system-ui, sans-serif"
      fontSize="27"
      fontWeight="700"
      letterSpacing="-0.5"
    >
      {BRAND}
    </text>
  </svg>
);

export default NoiWordmark;
