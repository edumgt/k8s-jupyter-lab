from redis import Redis
from redis.exceptions import RedisError


def get_redis_status(redis_url: str) -> tuple[bool, str]:
    client = None
    try:
        client = Redis.from_url(redis_url, socket_timeout=1.5, socket_connect_timeout=1.5)
        pong = client.ping()
        key_count = client.dbsize()
        return bool(pong), f"ping ok, keys={key_count}"
    except RedisError as exc:
        return False, str(exc)
    finally:
        if client is not None:
            client.close()
