// Schemify Docs - Client-side interactivity

function initTheme() {
  const saved = localStorage.getItem("theme");
  if (saved) document.documentElement.setAttribute("data-theme", saved);
}

function toggleTheme() {
  const html = document.documentElement;
  const current = html.getAttribute("data-theme") || "light";
  const next = current === "dark" ? "light" : "dark";
  html.setAttribute("data-theme", next);
  localStorage.setItem("theme", next);
}

function initSidebarState() {
  const shouldClose = localStorage.getItem("sidebar_closed") !== "false";
  const sidebar = document.querySelector(".sidebar");
  const content = document.querySelector(".content");
  if (shouldClose) {
    sidebar?.classList.add("closed");
    content?.classList.add("expanded");
  }
}

function toggleSidebar() {
  const sidebar = document.querySelector(".sidebar");
  const content = document.querySelector(".content");
  const isClosed = sidebar?.classList.toggle("closed");
  content?.classList.toggle("expanded");
  localStorage.setItem("sidebar_closed", isClosed ? "true" : "false");
}

function initScrollSpy() {
  const centerEl = document.getElementById("topbar-center");
  if (!centerEl) return;

  const headers = document.querySelectorAll(".content h1, .content h2, .content h3");
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          centerEl.textContent = entry.target.textContent || "";
        }
      }
    },
    { rootMargin: "0px 0px -80% 0px", threshold: 0.1 }
  );

  headers.forEach((h) => observer.observe(h));
}

function highlightActiveSidebarLink() {
  const currentPath = window.location.pathname;
  document.querySelectorAll(".sidebar a").forEach((a) => {
    const href = a.getAttribute("href");
    if (href === currentPath) {
      a.classList.add("active");
    } else {
      a.classList.remove("active");
    }
  });
}

function formatNotes() {
  document.querySelectorAll("blockquote p").forEach((p) => {
    const text = p.textContent?.trim() || "";
    if (text.startsWith("[!NOTE]")) {
      p.closest("blockquote")?.classList.add("note");
      p.innerHTML = p.innerHTML.replace("[!NOTE]", "<strong>NOTE</strong>");
    }
    if (text.startsWith("[!WARNING]")) {
      p.closest("blockquote")?.classList.add("warning");
      p.innerHTML = p.innerHTML.replace("[!WARNING]", "<strong>WARNING</strong>");
    }
    if (text.startsWith("[!TIP]")) {
      p.closest("blockquote")?.classList.add("tip");
      p.innerHTML = p.innerHTML.replace("[!TIP]", "<strong>TIP</strong>");
    }
  });
}

function attachListeners() {
  document.querySelector(".theme-toggle")?.addEventListener("click", toggleTheme);
  document.querySelector(".sidebar-toggle")?.addEventListener("click", toggleSidebar);
}

function init() {
  initTheme();
  initSidebarState();
  initScrollSpy();
  highlightActiveSidebarLink();
  formatNotes();
  attachListeners();
}

// HTMX re-init after page swap
document.body.addEventListener("htmx:afterSwap", () => {
  initSidebarState();
  initScrollSpy();
  highlightActiveSidebarLink();
  formatNotes();
  // Re-attach sidebar toggle (sidebar is inside #app which gets swapped)
  document.querySelector(".sidebar-toggle")?.addEventListener("click", toggleSidebar);
});

document.addEventListener("DOMContentLoaded", init);
