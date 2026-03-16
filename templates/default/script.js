(function () {
	const saved = localStorage.getItem('theme');
	if (saved) document.documentElement.setAttribute('data-theme', saved);

	document.addEventListener('DOMContentLoaded', function () {
		updateThemeButton();
	});
})();

function currentTheme() {
	return document.documentElement.getAttribute('data-theme') || 'dark';
}

var SUN_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/></svg>';
var MOON_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401"/></svg>';

function updateThemeButton() {
	var btn = document.querySelector('.theme-toggle');
	if (btn) btn.innerHTML = currentTheme() === 'light' ? MOON_SVG : SUN_SVG;
}

function toggleNav() {
	document.querySelector('.nav-links').classList.toggle('open');
}

function toggleTheme() {
	const next = currentTheme() === 'light' ? 'dark' : 'light';
	document.documentElement.setAttribute('data-theme', next);
	localStorage.setItem('theme', next);
	updateThemeButton();
}
