import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        felt: "#0b3d2e",
        feltDark: "#072218",
        cardBack: "#5b1a1a",
      },
      fontFamily: {
        display: ["ui-serif", "Georgia", "serif"],
      },
    },
  },
  plugins: [],
};

export default config;
