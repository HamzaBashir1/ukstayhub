// utils/geocode.js
import { geocode } from "./geoapify.js";

export async function getLatLngFromAddress(address) {
  if (!address) return null;

  try {
    const hit = await geocode(address);
    if (hit && hit.latitude != null && hit.longitude != null) {
      return { latitude: hit.latitude, longitude: hit.longitude };
    }
    console.warn(`⚠️ No results for address: ${address}`);
    return null;
  } catch (error) {
    console.error("❌ Error in geocoding:", error.message || error);
    return null;
  }
}

/**
 * Helper with a short pause between calls so bulk imports stay
 * within Geoapify's free-tier rate limit.
 */
export async function geocodeWithDelay(address, delay = 250) {
  const coords = await getLatLngFromAddress(address);
  await new Promise((resolve) => setTimeout(resolve, delay));
  return coords;
}
