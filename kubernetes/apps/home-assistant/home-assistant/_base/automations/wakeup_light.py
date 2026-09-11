from datetime import datetime, timedelta, time
from zoneinfo import ZoneInfo
LIGHT             = "light.bedroom_light_main"
ALARM_SENSOR      = "sensor.sm_a546b_next_alarm"
ENABLE_SWITCH     = "input_boolean.wakeup_light"   # kill switch (create in HA UI or config)
RAMP_BEFORE_MINUTES = 30           # ramp duration
MIN_BRIGHTNESS_PCT  = 2            # starting brightness
MAX_BRIGHTNESS_PCT  = 100          # brightness at alarm time
# Kelvin-native light (min_color_temp_kelvin 2202 / max 6535):
# current HA light.turn_on takes color_temp_kelvin=...; color_temp= (mireds)
# and kelvin= were deprecated and REMOVED from the service schema.
START_KELVIN        = 2200         # warm
END_KELVIN          = 3800         # cooler at alarm time
RAMP_INTERVAL_SEC   = 60           # poll interval (matches cron)
ALARM_WINDOW_START  = time(4, 0)   # 04:00 inclusive
ALARM_WINDOW_END    = time(9, 30)  # 09:30 exclusive (strictly before)
_TZ = ZoneInfo("Europe/Amsterdam")
@time_trigger("once(now)", "cron(* * * * *)")
def wakeup_ramp(**kwargs):
    task.unique("wakeup_ramp")
    if ENABLE_SWITCH and (not state.exist(ENABLE_SWITCH)
                          or state.get(ENABLE_SWITCH).lower() in ("off", "false", "0")):
        log.debug("Wake-up light functionality turned off")
        return
    raw = state.get(ALARM_SENSOR)
    if not raw:
        return
    try:
        alarm = datetime.fromisoformat(raw).astimezone(_TZ)
    except ValueError:
        return
    now = datetime.now(_TZ)
    alarm_time = alarm.time()
    if not (ALARM_WINDOW_START <= alarm_time < ALARM_WINDOW_END):
        log.debug("Alarm outside morning window")
        return
    ramp_start = alarm - timedelta(minutes=RAMP_BEFORE_MINUTES)
    if now >= alarm:                       # done: stays at max, no-op
        log.debug("Max reached")
        return
    if now < ramp_start:                   # not ramping yet
        log.debug("Not yet ramping")
        return
    progress = (now - ramp_start) / (alarm - ramp_start)          # 0..1
    brightness = MIN_BRIGHTNESS_PCT + (MAX_BRIGHTNESS_PCT - MIN_BRIGHTNESS_PCT) * progress
    kelvin = START_KELVIN + int((END_KELVIN - START_KELVIN) * progress)
    light.turn_on(entity_id=LIGHT,
                  brightness_pct=brightness,
                  color_temp_kelvin=kelvin)
    log.debug(f"progress: {progress}, brightness: {brightness}, kelvin: {kelvin}")
