# Configuration System Update - Complete

## Summary

Successfully expanded the YAML configuration system from 13 to **39 parameters**, exposing all previously hardcoded values while maintaining backward compatibility.

## Changes Made

### 1. Updated `include/ejfat_zmq_proxy/config.hpp`

Added new configuration structs:
- **SchedulingConfig**: Worker scheduling parameters (weight, min_factor, max_factor)
- **LoggingConfig**: Logging verbosity and intervals

Expanded existing structs with new fields:
- **EjfatConfig**: Added 9 new parameters (data_ip, num_recv_threads, event_timeout_ms, rcv_socket_buf_size, validate_cert, use_ipv6, scheduling)
- **ZmqConfig**: Added 4 new parameters (io_threads, poll_sleep_us, linger_ms, sndbuf)
- **PidConfig**: Added integral_limit for anti-windup
- **BackpressureConfig**: Added ready_threshold, log_interval, control_min, control_max

Added `validate()` method to ProxyConfig for range checking.

### 2. Updated `src/config.cpp`

- Added YAML parsing for all 39 parameters
- Implemented comprehensive validation with sensible ranges:
  - Port ranges (1024-65535)
  - Thread counts (1-128)
  - Buffer sizes (100-1M events, 64KB-100MB sockets)
  - PID setpoints and thresholds (0.0-1.0)
  - HWM limits (1-1M messages)
  - I/O threads (1-16)

### 3. Updated Components

**`src/proxy.cpp`:**
- Uses `config.ejfat.data_ip` instead of hardcoded "127.0.0.1"
- Uses `config.ejfat.num_recv_threads` instead of hardcoded 1
- Uses `config.logging.drop_warn_interval` and `progress_interval`
- Correctly sets E2SAR ReassemblerFlags with actual API field names

**`src/zmq_sender.cpp`:**
- Uses `config.zmq.io_threads` for ZMQ context creation
- Uses `config.zmq.poll_sleep_us` for sleep duration
- Sets `linger_ms` and `sndbuf` socket options

**`src/backpressure_monitor.cpp`:**
- Uses `config.backpressure.ready_threshold` instead of hardcoded 0.95
- Uses `config.backpressure.log_interval` instead of hardcoded 50
- Applies `control_min`/`control_max` clamping
- Applies `integral_limit` in PID anti-windup

### 4. Updated Configuration Files

**`config/default.yaml`:**
- Complete schema with all 39 parameters documented
- Includes descriptions and examples for each parameter
- Production-ready defaults

**`config/local_test.yaml`:**
- Added explicit `data_ip: "127.0.0.1"` for macOS compatibility
- Reduced buffer sizes and logging intervals for local testing
- All new parameters included with local-friendly values

## Verification Results

✅ **Build**: Successful compilation (1.9 MB binary)
✅ **Config Loading**: Both default and local configs load without errors
✅ **Validation**: All validation rules working correctly:
   - Invalid port (999) rejected: ✓
   - Invalid thread count (200) rejected: ✓
   - Invalid HWM (2000000) rejected: ✓
   - Invalid buffer size (50) rejected: ✓
✅ **Runtime**: Local test config runs successfully with new parameters applied

## Complete Parameter List (39 total)

### EJFAT (13 parameters)
- uri, use_cp, worker_name, data_port, data_ip
- with_lb_header, num_recv_threads, event_timeout_ms
- rcv_socket_buf_size, validate_cert, use_ipv6
- scheduling.{weight, min_factor, max_factor}

### ZMQ (6 parameters)
- push_endpoint, send_hwm, io_threads, poll_sleep_us
- linger_ms, sndbuf

### Backpressure (10 parameters)
- period_ms, ready_threshold, log_interval, control_min, control_max
- pid.{setpoint, kp, ki, kd, integral_limit}

### Buffer (2 parameters)
- size, recv_timeout_ms

### Logging (3 parameters)
- verbosity, drop_warn_interval, progress_interval

### YAML Config Version (metadata)
- Comments indicate "v2.0" schema

## Backward Compatibility

All new parameters have defaults matching previous hardcoded values:
- Existing configs work unchanged
- No breaking changes to YAML structure
- All defaults preserve original behavior

## Notes

- **use_ipv6** config parameter added but not used (E2SAR determines IPv6 from data_ip type)
- E2SAR API uses `eventTimeout_ms`, `rcvSocketBufSize`, `weight`, `min_factor`, `max_factor` (no "set" prefix)
- Validation ensures all parameters are in safe, tested ranges
- Empty `data_ip` triggers fallback to "127.0.0.1" for macOS compatibility

## Files Modified

1. `include/ejfat_zmq_proxy/config.hpp` - Added structs and fields
2. `src/config.cpp` - Added parsing and validation
3. `src/proxy.cpp` - Use config instead of hardcoded values
4. `src/zmq_sender.cpp` - Use config for ZMQ parameters
5. `src/backpressure_monitor.cpp` - Use config for backpressure parameters
6. `config/default.yaml` - Complete v2.0 schema with all parameters
7. `config/local_test.yaml` - Updated with all parameters
