import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import typography from '@tailwindcss/typography'

const apiTarget = process.env.VITE_API_TARGET ?? 'http://localhost:4000'

export default defineConfig({
  plugins: [react(), tailwindcss({ plugins: [typography] })],
  base: '/',
  build: {
    outDir: '../priv/static/app',
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    proxy: {
      '/api': apiTarget,
      '/socket': {
        target: apiTarget,
        ws: true,
      },
    },
  },
})
