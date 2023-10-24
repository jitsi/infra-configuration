local cache = require "util.cache"
local jwt = module:require "luajwtjitsi";
local uuid = require "uuid"

local A = {}
A.__index = A

function A.new(key_path, key_id, issuer, ttl_threshold, cache_size)
   local self = setmetatable({}, A)

   self.key_path = key_path
   self.key_id = key_id
   self.issuer = issuer
   self.ttl_threshold = ttl_threshold
   self.cache = cache.new(cache_size)

   local f = assert(io.open(self.key_path), "invalid asap key path")
   self.signing_key = assert(f:read("*all"), "unable to read asap key")
   f:close();
   return self
end

function A:generate(audience, ttl)
    -- First, attempt to grab a valid key from the cache.
    local exp_cache_key   = 'asap_exp.'..audience
    local token_cache_key = 'asap_token.'..audience
	local exp   = self.cache:get(exp_cache_key)
	local token = self.cache:get(token_cache_key)
	local now = os.time()
	if token ~= nil and exp ~= nil then
	   exp = tonumber(exp)
	   if (exp - now) > self.ttl_threshold then
		  return token
	   end
	end

	local exp = now + ttl
	local claims = {
	   iss = self.issuer,
	   jti = uuid(),
	   aud = audience,
	   nbf = now,
	   iat = now,
	   exp = exp
	}

	local token, err = jwt.encode(claims, self.signing_key, "RS256", {kid = self.key_id})
	if not err then
	   token = 'Bearer '..token
	   self.cache:set(exp_cache_key, exp)
	   self.cache:set(token_cache_key, token)
	   return token
	else
	   return nil
	end
end

return setmetatable(A, {
    __call = function(cls, ...)
	   return cls.new(...)
	end,
})
