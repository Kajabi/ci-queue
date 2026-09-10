local queue_key = KEYS[1]
local zset_key = KEYS[2]
local processed_key = KEYS[3]
local worker_queue_key = KEYS[4]
local owners_key = KEYS[5]

local current_time = ARGV[1]
local ttl = ARGV[2]

local test = redis.call('rpop', queue_key)
if test then
  redis.call('zadd', zset_key, current_time, test)
  redis.call('lpush', worker_queue_key, test)
  redis.call('hset', owners_key, test, worker_queue_key)

  -- Expire at write time. These keys used to rely on an EXPIRE at the tail of
  -- CI::Queue::Redis::Worker#poll, which never runs for a worker that is killed,
  -- cancelled, OOMs or loses its Redis connection -- leaking the key forever.
  redis.call('expire', zset_key, ttl)
  redis.call('expire', worker_queue_key, ttl)
  redis.call('expire', owners_key, ttl)

  return test
else
  return nil
end
