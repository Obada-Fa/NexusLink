export function Sparkline({
  data,
  width = 120,
  height = 36,
  color = '#4ade80',
  strokeWidth = 1.5,
}: {
  data: number[];
  width?: number;
  height?: number;
  color?: string;
  strokeWidth?: number;
}) {
  if (data.length < 2) {
    return (
      <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
        <line
          x1={0}
          y1={height / 2}
          x2={width}
          y2={height / 2}
          stroke={color}
          strokeWidth={strokeWidth}
          strokeLinecap="round"
          opacity={0.3}
        />
      </svg>
    );
  }

  const max = Math.max(...data);
  const min = Math.min(...data);
  const range = max - min || 1;

  const padding = strokeWidth;
  const chartW = width - padding * 2;
  const chartH = height - padding * 2;

  const points = data.map((val, i) => {
    const x = padding + (i / (data.length - 1)) * chartW;
    const y = padding + chartH - ((val - min) / range) * chartH;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });

  const pathD = `M${points.join(' L')}`;

  const lastX = padding + chartW;
  const lastY = padding + chartH - ((data[data.length - 1] - min) / range) * chartH;
  const areaD = `${pathD} L${lastX.toFixed(1)},${(height - padding).toFixed(1)} L${padding.toFixed(1)},${(height - padding).toFixed(1)} Z`;

  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
      <path d={areaD} fill={color} opacity={0.08} />
      <path
        d={pathD}
        fill="none"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
