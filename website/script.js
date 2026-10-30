'use strict';
const toggle = document.querySelector('.menu-toggle');
const navigation = document.querySelector('#navigation');
function closeMenu() { navigation.classList.remove('open'); toggle.setAttribute('aria-expanded', 'false'); }
toggle.addEventListener('click', () => { const open = toggle.getAttribute('aria-expanded') !== 'true'; toggle.setAttribute('aria-expanded', String(open)); navigation.classList.toggle('open', open); });
navigation.querySelectorAll('a').forEach(link => link.addEventListener('click', closeMenu));
document.addEventListener('keydown', event => { if (event.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') { closeMenu(); toggle.focus(); } });
const concepts = [
 ['Your cluster starts with you.', 'Independent devices. One personal computing environment.'],
 ['More than the screen in your hand.', 'The vision: powerful machines supporting the device you are using.'],
 ['Your memories. Your machines.', 'A personal cloud designed around storage you control.']
];
document.querySelectorAll('.step').forEach(button => button.addEventListener('click', () => {
 const index = Number(button.dataset.step);
 document.querySelectorAll('.step').forEach(item => { const selected = item === button; item.classList.toggle('active', selected); item.setAttribute('aria-pressed', String(selected)); });
 document.querySelector('#concept-title').textContent = concepts[index][0];
 document.querySelector('#concept-description').textContent = concepts[index][1];
 document.querySelector('#concept-index').textContent = `0${index + 1}—03`;
}));
