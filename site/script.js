(function () {
  "use strict";

  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  // ---------- Ridiculous uptime counter ----------
  var started = Date.now();
  var uptimeValue = document.getElementById("uptime-value");
  var uptimeDuration = document.getElementById("uptime-duration");
  var uptimeNines = document.getElementById("uptime-nines");

  function formatDuration(totalSeconds) {
    var h = Math.floor(totalSeconds / 3600);
    var m = Math.floor((totalSeconds % 3600) / 60);
    var s = totalSeconds % 60;
    var parts = [];
    if (h) parts.push(h + (h === 1 ? " hour" : " hours"));
    if (m) parts.push(m + (m === 1 ? " minute" : " minutes"));
    parts.push(s + (s === 1 ? " second" : " seconds"));
    return parts.join(", ");
  }

  function tickUptime() {
    var seconds = Math.floor((Date.now() - started) / 1000);
    // One extra nine every second, because confidence scales linearly.
    var nines = Math.min(9 + seconds, 64);
    uptimeValue.textContent = "99." + "9".repeat(nines - 2) + "%";
    uptimeDuration.textContent = formatDuration(seconds);
    uptimeNines.textContent = nines >= 64 ? "too many" : String(nines);
  }

  tickUptime();
  setInterval(tickUptime, 1000);

  // ---------- Jokes and harmless chaos ----------
  var jokes = [
    "Why did the cloud engineer break up with the server? There was no chemistry, only latency.",
    "Our disaster recovery plan is a sticky note that says \"try turning the region off and on again.\"",
    "This site is serverless in the sense that nobody can find the server.",
    "We scaled to zero users with remarkable efficiency.",
    "The YAML was perfect on the first try. That is the joke.",
    "Kubernetes was considered and politely declined. It is a single page.",
    "Our cost optimization strategy is closing the browser tab quickly.",
    "Infrastructure as Code: because clicking things is how legends get lost.",
    "Fun fact: the cloud is just someone else's computer, wearing a nicer hat.",
    "We have achieved five nines. They are all in the uptime counter.",
    "Terraform plan says: 1 to add, 0 to change, 1 to explain to your manager.",
    "The health check passed. Nobody knows what it checked, but it passed."
  ];

  var moods = [
    ["Fluffy", "All clouds are white and puffy. No grey ones detected."],
    ["Cumulus maximus", "Clouds are stacking up nicely. Capacity planning: vibes."],
    ["Partly sunny", "A sunbeam has entered the datacenter. Investigating."],
    ["Extremely elastic", "Scaled out to three extra clouds for no reason."],
    ["Suspiciously green", "Every dashboard is green. We are choosing to believe it."]
  ];

  var button = document.getElementById("chaos-button");
  var jokeEl = document.getElementById("joke");
  var health = document.querySelector(".health");
  var healthLabel = document.getElementById("health-label");
  var healthDetail = document.getElementById("health-detail");
  var rack = document.querySelector(".rack");
  var sky = document.querySelector(".sky");
  var lastJoke = -1;
  var presses = 0;

  function pick(list, avoid) {
    var i;
    do {
      i = Math.floor(Math.random() * list.length);
    } while (list.length > 1 && i === avoid);
    return i;
  }

  function spawnCloud() {
    if (reducedMotion.matches) return;
    var svgNS = "http://www.w3.org/2000/svg";
    var cloud = document.createElementNS(svgNS, "svg");
    cloud.setAttribute("viewBox", "0 0 200 100");
    cloud.setAttribute("class", "cloud cloud--extra");
    cloud.style.top = Math.round(5 + Math.random() * 80) + "%";
    cloud.style.width = Math.round(90 + Math.random() * 160) + "px";
    var use = document.createElementNS(svgNS, "use");
    use.setAttribute("href", "#cloud-shape");
    cloud.appendChild(use);
    cloud.addEventListener("animationend", function () {
      cloud.remove();
    });
    sky.appendChild(cloud);
  }

  button.addEventListener("click", function () {
    presses += 1;

    lastJoke = pick(jokes, lastJoke);
    jokeEl.textContent = jokes[lastJoke];
    jokeEl.classList.remove("is-new");
    void jokeEl.offsetWidth;
    jokeEl.classList.add("is-new");

    var mood = moods[presses % moods.length];
    healthLabel.textContent = mood[0];
    healthDetail.textContent = mood[1];
    health.setAttribute("data-mood", presses % 2 ? "party" : "calm");

    rack.classList.add("is-turbo");
    setTimeout(function () {
      rack.classList.remove("is-turbo");
    }, 2000);

    for (var i = 0; i < 3; i++) {
      setTimeout(spawnCloud, i * 250);
    }

    button.textContent = presses < 5 ? "Deploy even more cloud" : "Okay, that is plenty of cloud";
  });
})();
