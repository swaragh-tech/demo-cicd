document.addEventListener("DOMContentLoaded", () => {
  const date = new Date();
  const footer = document.querySelector("footer p");
  if (footer) {
    footer.textContent += ` | Loaded on: ${date.toLocaleString()}`;
  }
});