import CryptoJS from "crypto-js";
import { parseHTML } from "linkedom";

globalThis.CryptoJS = CryptoJS;
globalThis.__tetoParseDocument = function (source) {
  return parseHTML(String(source || "")).document;
};
