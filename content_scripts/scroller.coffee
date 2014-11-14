#
# activatedElement is different from document.activeElement -- the latter seems to be reserved mostly for
# input elements. This mechanism allows us to decide whether to scroll a div or to scroll the whole document.
#
activatedElement = null

scrollProperties =
  x: {
    axisName: 'scrollLeft'
    max: 'scrollWidth'
    viewSize: 'clientHeight'
  }
  y: {
    axisName: 'scrollTop'
    max: 'scrollHeight'
    viewSize: 'clientWidth'
  }

getDimension = (el, direction, amount) ->
  if Utils.isString amount
    name = amount
    # the clientSizes of the body are the dimensions of the entire page, but the viewport should only be the
    # part visible through the window
    if name is 'viewSize' and el is document.body
      if direction is 'x' then window.innerWidth else window.innerHeight
    else
      el[scrollProperties[direction][name]]
  else
    amount

# Perform a scroll. Return true if we successfully scrolled by the requested amount, and false otherwise.
performScroll = (element, direction, amount) ->
  axisName = scrollProperties[direction].axisName
  before = element[axisName]
  element[axisName] += amount
  element[axisName] == amount + before

# Test whether element should be scrolled.
shouldScroll = (element, direction) ->
  computedStyle = window.getComputedStyle(element)
  # Elements with `overflow: hidden` should not be scrolled.
  return false if computedStyle.getPropertyValue("overflow-#{direction}") == "hidden"
  # Non-visible elements should not be scrolled.
  return false if computedStyle.getPropertyValue("visibility") in ["hidden", "collapse"]
  return false if computedStyle.getPropertyValue("display") == "none"
  true

# Test whether element actually scrolls in the direction required when asked to do so.  Due to chrome bug
# 110149, scrollHeight and clientHeight cannot be used to reliably determine whether an element will scroll.
# Instead, we scroll the element by 1 or -1 and see if it moved (then put it back).
# Bug verified in Chrome 38.0.2125.104.
isScrollPossible = (element, direction, amount, factor) ->
  # amount, here, is treated as a relative amount, which is correct for relative scrolls. For absolute scrolls
  # (only gg, G, and friends), amount can be either 'max' or zero. In the former case, we're definitely
  # scrolling forwards, so any positive value will do for delta.  In the latter, we're definitely scrolling
  # backwards, so a delta of -1 will do.
  delta = factor * getDimension(element, direction, amount) || -1
  delta = Math.sign delta # 1 or -1
  performScroll(element, direction, delta) and performScroll(element, direction, -delta)

# Find the element which we should and can scroll (or document.body).
findScrollableElement = (element, direction, amount, factor = 1) ->
  while element != document.body and
    not (isScrollPossible(element, direction, amount, factor) and shouldScroll(element, direction))
      element = element.parentElement || document.body
  element

checkVisibility = (element) ->
  # if the activated element has been scrolled completely offscreen, subsequent changes in its scroll
  # position will not provide any more visual feedback to the user. therefore we deactivate it so that
  # subsequent scrolls only move the parent element.
  rect = activatedElement.getBoundingClientRect()
  if (rect.bottom < 0 || rect.top > window.innerHeight || rect.right < 0 || rect.left > window.innerWidth)
    activatedElement = element

# How scrolling is handled:
#   - For non-smooth scrolling, the entire scroll happens immediately.
#   - For smooth scrolling with distinct key presses, a separate animator is initiated for each key press.
#     Therefore, several animators may be active at the same time.  This ensures that two quick taps on `j`
#     scroll to the same position as two slower taps.
#   - For smooth scrolling with keyboard repeat (continuous scrolling), the most recently-activated animator
#     continues scrolling at least until its corresponding keyup event is received.  We never initiate a new
#     animator on keyboard repeat.

CoreScroller =
  init: (frontendSettings) ->
    @settings = frontendSettings
    @time = 0
    @lastEvent = null
    @keyIsDown = false

    handlerStack.push
      keydown: (event) =>
        @keyIsDown = true
        @lastEvent = event
      keyup: =>
        @keyIsDown = false
        @time += 1

  # Calibration fudge factors for continuous scrolling.  The calibration value starts at 1.0.  We then
  # increase it (until it exceeds @maxCalibration) if we guess that the scroll is too slow, or decrease it
  # (until it is less than @minCalibration) if we guess that the scroll is too fast.  The cutoff point for
  # which guess we make is @calibrationBoundary. We require: 0 < @minCalibration <= 1 <= @maxCalibration.
  minCalibration: 0.5 # Controls how much we're willing to slow scrolls down; smaller => more slow down.
  maxCalibration: 1.6 # Controls how much we're willing to speed scrolls up; bigger => more speed up.
  calibrationBoundary: 150 # Boundary between scrolls which are considered too slow, and those too fast.

  # Scroll element by a relative amount (a number) in some direction.
  scroll: (element, direction, amount) ->
    return unless amount

    unless @settings.get "smoothScroll"
      # Jump scrolling.
      performScroll element, direction, amount
      checkVisibility element
      return

    # We don't activate new animators on keyboard repeats.
    return if @lastEvent?.repeat

    activationTime = ++@time
    isMyKeyStillDown = => @time == activationTime and @keyIsDown

    # Store amount's sign and make amount positive; the logic is clearer when amount is positive.
    sign = Math.sign amount
    amount = Math.abs amount

    # Duration in ms. Allow a bit longer for longer scrolls.
    duration = Math.max 100, 20 * Math.log amount

    totalDelta = 0
    totalElapsed = 0.0
    calibration = 1.0
    previousTimestamp = null
    animatorId = null

    advanceAnimation = -> animatorId = requestAnimationFrame animate
    cancelAnimation = -> cancelAnimationFrame animatorId

    animate = (timestamp) =>
      previousTimestamp ?= timestamp
      return advanceAnimation() if timestamp == previousTimestamp

      # The elapsed time is typically about 16ms.
      elapsed = timestamp - previousTimestamp
      totalElapsed += elapsed
      previousTimestamp = timestamp

      # The constants in the duration calculation, above, are chosen to provide reasonable scroll speeds for
      # distinct keypresses.  For continuous scrolls, some scrolls are too slow, and others too fast. Here, we
      # speed up the slower scrolls, and slow down the faster scrolls.
      if isMyKeyStillDown() and 50 <= totalElapsed and @minCalibration <= calibration <= @maxCalibration
        calibration *= 1.05 if 1.05 * calibration * amount < @calibrationBoundary # Speed up slow scrolls.
        calibration *= 0.95 if @calibrationBoundary < 0.95 * calibration * amount # Slow down fast scrolls.

      # Calculate the initial delta, rounding up to ensure progress.  Then, adjust delta to account for the
      # current scroll state.
      delta = Math.ceil amount * (elapsed / duration) * calibration
      delta = if isMyKeyStillDown() then delta else Math.max 0, Math.min delta, amount - totalDelta

      if delta and performScroll element, direction, sign * delta
        totalDelta += delta
        advanceAnimation()
      else
        checkVisibility element
        cancelAnimation()

    advanceAnimation()

Scroller =
  init: (frontendSettings) ->
    handlerStack.push DOMActivate: -> activatedElement = event.target
    CoreScroller.init frontendSettings

  # scroll the active element in :direction by :amount * :factor.
  # :factor is needed because :amount can take on string values, which scrollBy converts to element dimensions.
  scrollBy: (direction, amount, factor = 1) ->
    # if this is called before domReady, just use the window scroll function
    if (!document.body and amount instanceof Number)
      if (direction == "x")
        window.scrollBy(amount, 0)
      else
        window.scrollBy(0, amount)
      return

    activatedElement ||= document.body
    return unless activatedElement

    element = findScrollableElement activatedElement, direction, amount, factor
    elementAmount = factor * getDimension element, direction, amount
    CoreScroller.scroll element, direction, elementAmount

  scrollTo: (direction, pos) ->
    return unless document.body or activatedElement
    activatedElement ||= document.body

    element = findScrollableElement activatedElement, direction, pos
    amount = getDimension(element,direction,pos) - element[scrollProperties[direction].axisName]
    CoreScroller.scroll element, direction, amount

root = exports ? window
root.Scroller = Scroller
