// The translate function from useT() is a hook result, so it only exists inside
// components. A label defined at module scope (a constants array of menu items,
// say) has no hook to call, and a bare string there is invisible to the key
// scanner. Wrap it in msg() to keep the English text and mark it as a catalog
// key, then pass it through the translate function when rendering.
function msg(en: string): string {
	return en;
}

export { msg };
