const toggle = document.querySelector('.nav-toggle');
const navigation = document.getElementById('site-nav');
if (toggle && navigation) {
  toggle.addEventListener('click', () => {
    const expanded = navigation.classList.toggle('open');
    toggle.setAttribute('aria-expanded', String(expanded));
  });
}
