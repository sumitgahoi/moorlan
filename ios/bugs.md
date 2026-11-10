FIXED: changing default — stop-before-save reconnect; stale multi-save; isEnabled=true on every peer re-auth → "Allow Moorlan to add VPN". writeOnDemand skips no-ops, only enables isEnabled on new default, retries stale.

FIXED: foreign VPN takes over → iOS leaves Moorlan isEnabled=false → start fails as configurationDisabled / “VPN permission”. Follow wireguard-apple TunnelContainer.startActivation: re-enable+save then recurse; reload only on configurationInvalid/Stale; max 8 attempts.
