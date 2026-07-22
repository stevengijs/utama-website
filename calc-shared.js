/* Shared ROI-calculator logic, used by /the-maison/, /moka/ and /the-maison/brochure/.
   Keeping the core formula and the scenario-pin renderer in ONE file means a future
   change (or bug fix) only has to happen once, instead of drifting between the main
   pages and the brochure page like the ROI% and the slider pins both did before. */

/* price: absolute amount. nightly: absolute amount. occFraction/costsFraction: 0-1 decimals. */
function roiCalc(price, nightly, occFraction, costsFraction){
  const gross = nightly * 365 * occFraction;
  const net = gross * (1 - costsFraction);
  const roi = price > 0 ? net / price * 100 : 0;
  const payback = net > 0 ? price / net : 0;
  return { gross, net, roi, payback };
}

/* Renders small clickable pins on a nightly-rate <input type=range> marking each
   scenario's nightly rate. sliderEl/pinsEl are DOM elements (not ids), scenarios is
   an array of {label, occ (0-100), nightly}, selIndex is the currently active scenario
   index, applyFnName is the global function name to call on click (receives the index),
   formatMoney formats a number as currency, lang picks the label when label is an
   {nl,en} object (pass null/undefined when labels are plain strings). */
function renderScenarioPins(sliderEl, pinsEl, scenarios, selIndex, applyFnName, formatMoney, lang){
  if(!sliderEl || !pinsEl) return;
  const min = +sliderEl.min, max = +sliderEl.max, w = sliderEl.offsetWidth, thumb = 20;
  if(!w) return;
  pinsEl.innerHTML = scenarios.map(function(s, i){
    const p = max > min ? (s.nightly - min) / (max - min) : 0;
    const x = thumb / 2 + p * (w - thumb);
    const label = (s.label && typeof s.label === 'object') ? (s.label[lang] || s.label.nl) : s.label;
    return `<div class="pin ${i === selIndex ? 'cur' : ''}" style="left:${x}px" data-lbl="${label}" title="${label}: ${formatMoney(s.nightly)}" onclick="${applyFnName}(${i})"></div>`;
  }).join("");
}
