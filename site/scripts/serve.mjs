// npm run dev: the website at http://127.0.0.1:8787, as it is deployed.
import { fileURLToPath } from "node:url";
import { serve } from "./serve-lib.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
const { url } = await serve(root, Number(process.env.PORT ?? 8787));
console.log(`Seaglass's website: ${url}`);
