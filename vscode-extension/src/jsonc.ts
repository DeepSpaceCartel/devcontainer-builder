// devcontainer.json is JSON with comments and trailing commas. A small
// stripper is enough for reading a few keys - no runtime dependency.
// Comments and trailing commas are dropped in one pass over the tokens, so
// strings (e.g. "a,]" or "http://x") are never touched.
export function parseJsonc(text: string): unknown {
  let out = "";
  // Where in `out` the last comma is, while only whitespace and comments
  // have followed it.
  let comma = -1;
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      const start = i++;
      while (i < text.length && text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
      out += text.slice(start, ++i);
      comma = -1;
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
    } else if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end < 0 ? text.length : end + 2;
    } else {
      if ((c === "}" || c === "]") && comma >= 0) out = out.slice(0, comma) + out.slice(comma + 1);
      if (c === ",") comma = out.length;
      else if (!/\s/.test(c)) comma = -1;
      out += c;
      i++;
    }
  }
  return JSON.parse(out);
}
