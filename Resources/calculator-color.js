/* CSS Color 4 parsing/conversion via Culori; query text is data, never code. */
function switcharooColor(query) {
  const match = query.trim().match(/^(.*?)(?:\s+(?:in|to|as)\s+(hex|hexa|rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch))?$/i);
  if (!match) return null;
  let source = match[1].trim(), target = (match[2] || 'hex').toLowerCase();
  // A six-digit bare hex is accepted only if it contains a letter, so 123456 stays math.
  if (/^[0-9a-f]{6}$/i.test(source) && /[a-f]/i.test(source)) source = '#'+source;
  const color = culori.parse(source);
  if (!color) return null;
  const converted = culori.converter(target === 'hex' || target === 'hexa' || target === 'rgba' ? 'rgb' : target === 'hsla' ? 'hsl' : target)(color);
  const formatted = target === 'hex' ? (color.alpha !== undefined && color.alpha < 1 ? culori.formatHex8(color) : culori.formatHex(color)) : target === 'hexa' ? culori.formatHex8(color) : target === 'rgb' || target === 'rgba' ? culori.formatRgb(color) : target === 'hsl' || target === 'hsla' ? culori.formatHsl(color) : culori.formatCss(converted);
  if (!formatted) return null;
  const rgb = culori.converter('rgb')(color);
  return JSON.stringify({result:{value:formatted,raw:formatted,kind:'Color',rgba:[rgb.r,rgb.g,rgb.b,rgb.alpha === undefined ? 1 : rgb.alpha],formats:[
    {name:'HEX',value:color.alpha !== undefined && color.alpha < 1 ? culori.formatHex8(color) : culori.formatHex(color)},
    {name:'RGB',value:culori.formatRgb(color)}, {name:'HSL',value:culori.formatHsl(color)},
    ...['hwb','lab','lch','oklab','oklch'].map(mode=>({name:mode.toUpperCase(),value:culori.formatCss(culori.converter(mode)(color))}))
  ]}});
}
