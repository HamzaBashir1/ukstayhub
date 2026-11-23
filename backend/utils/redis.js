// utils/redis.js
import { createClient } from "redis";

const redisUrl = process.env.UPSTASH_REDIS_URL || process.env.REDIS_URL;

const normalizedRedisUrl = (() => {
  if (!redisUrl) return undefined;

  const url = new URL(redisUrl);
  if (
    url.protocol === "redis:" &&
    (url.hostname === "upstash.io" || url.hostname.endsWith(".upstash.io"))
  ) {
    url.protocol = "rediss:";
  }
  return url.toString();
})();

const redisClient = createClient(
  normalizedRedisUrl ? { url: normalizedRedisUrl } : {}
);

redisClient.on("error", (err) =>
  console.error("Redis client error:", err.message)
);
redisClient.on("reconnecting", () =>
  console.warn("Redis reconnecting after connection loss")
);
redisClient.on("ready", () => console.log("Redis ready"));

export const connectRedis = async () => {
  if (!redisUrl) {
    console.error("Redis connection failed: configure UPSTASH_REDIS_URL or REDIS_URL");
    return false;
  }

  if (redisClient.isReady) return true;

  if (!redisClient.isOpen) {
    try {
      await redisClient.connect();
      return true;
    } catch (err) {
      console.error("Redis connection failed:", err.message);
    }
  }

  return redisClient.isReady;
};

export default redisClient;