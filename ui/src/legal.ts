// Textos legales BASE (plantilla). Deben ser revisados por un abogado de tu país antes del lanzamiento público.
// Personalízalos con las variables VITE_LEGAL_NAME, VITE_CONTACT_EMAIL y, cuando un abogado los apruebe, VITE_LEGAL_REVIEWED=true
// (mientras no sea "true", el panel muestra un aviso visible de «borrador sin revisar»).
export const legal = {
  name: (import.meta.env.VITE_LEGAL_NAME as string | undefined) || '[NOMBRE DEL OPERADOR]',
  email: (import.meta.env.VITE_CONTACT_EMAIL as string | undefined) || '[CORREO DE CONTACTO]',
  reviewed: import.meta.env.VITE_LEGAL_REVIEWED === 'true',
  updated: '2026-10',
};
export interface LegalDoc { title: string; sections: { h: string; p: string[] }[] }

export const terms = (): LegalDoc => ({
  title: 'Términos de uso',
  sections: [
    { h: '1. Qué es este servicio', p: [`${legal.name} (el «Operador») ofrece una herramienta para organizar y mantener listas de reproducción de canales (M3U, guías de programación y similares) y comprobar si los enlaces que TÚ agregas siguen funcionando.`, 'El servicio no produce, no aloja ni retransmite contenido audiovisual. Solo gestiona enlaces y metadatos que los propios usuarios aportan.'] },
    { h: '2. Tu responsabilidad sobre las fuentes', p: ['Solo debes agregar enlaces a contenido que tengas derecho a ver y usar (por ejemplo, señales gratuitas y abiertas, fuentes con licencia o tus propios servicios).', 'Eres el único responsable de los enlaces, credenciales y listas que cargas, y de cumplir las leyes de tu país, incluidas las de propiedad intelectual. Está prohibido usar el servicio para infringir derechos de terceros.'] },
    { h: '3. Listas personales y catálogo compartido', p: ['Tus listas son privadas. Los enlaces con credenciales, tokens o direcciones personales nunca se comparten.', 'Si activas la opción de compartir, solo se aportan al catálogo común enlaces públicos que no contengan datos personales, y únicamente después de aceptar este apartado. Puedes desactivarlo en cualquier momento; lo ya aceptado en el catálogo puede permanecer de forma anónima.', 'Podemos rechazar o retirar cualquier aporte, sin necesidad de explicación.'] },
    { h: '4. Retiro de contenido', p: [`Si crees que un enlace del catálogo infringe tus derechos, escribe a ${legal.email} indicando el enlace, tu titularidad y datos de contacto. Revisaremos el aviso y retiraremos el enlace cuando corresponda.`, 'Podemos suspender cuentas que reciban avisos repetidos o que incumplan estos términos.'] },
    { h: '5. Cuenta y uso aceptable', p: ['Debes ser mayor de edad en tu país para crear una cuenta. Mantén tu contraseña en secreto; eres responsable de lo que ocurra con ella.', 'No uses el servicio para atacar a terceros, sobrecargar sistemas ajenos, evadir los límites del plan o revender el acceso sin permiso.'] },
    { h: '6. Planes y pagos', p: ['Algunas funciones pueden requerir un plan de pago. Si se activan, los cobros los gestiona un proveedor externo y se te informará antes de cualquier cargo. Las condiciones del plan vigente se muestran en el panel.'] },
    { h: '7. Disponibilidad y límites de responsabilidad', p: ['El servicio se ofrece «tal cual», sin garantía de disponibilidad continua ni de que un canal funcione. Los enlaces pertenecen a terceros y pueden caer en cualquier momento.', 'En la medida que permita la ley, el Operador no responde por daños indirectos, pérdida de datos o interrupciones. Te recomendamos conservar copia de tus listas.'] },
    { h: '8. Cambios y contacto', p: [`Podemos actualizar estos términos; los cambios importantes se avisarán en el panel. Última actualización: ${legal.updated}.`, `Contacto: ${legal.email}.`] },
  ],
});

export const privacy = (): LegalDoc => ({
  title: 'Política de privacidad',
  sections: [
    { h: '1. Quién es el responsable', p: [`${legal.name}, contacto: ${legal.email}.`] },
    { h: '2. Qué datos tratamos', p: ['Cuenta: correo electrónico y contraseña (la contraseña se guarda cifrada por el proveedor de autenticación; nunca la vemos).', 'Contenido que aportas: tus listas, canales, enlaces, categorías, proxies y ajustes. Las contraseñas de proxy se guardan en un almacén de solo escritura.', 'Uso técnico: resultados de las comprobaciones de tus canales, registros del motor, y datos de seguridad básicos (dirección IP en registros del servidor, límites de uso).', 'Si eliges aparecer en el ranking: tu alias público. No mostramos tu correo.'] },
    { h: '3. Para qué los usamos', p: ['Para prestar el servicio (mantener tus listas, comprobar canales, generar tus enlaces), proteger el sistema contra abusos y mejorar el producto. No vendemos tus datos ni los usamos para publicidad de terceros.'] },
    { h: '4. Con quién se comparten', p: ['Solo con proveedores que operan el servicio por nuestra cuenta: alojamiento de base de datos y autenticación (Supabase), red y ejecución de la API (Cloudflare), ejecución del motor (por ejemplo GitHub) y, si se activan los cobros, el procesador de pagos. Cada uno tiene sus propias condiciones de privacidad.'] },
    { h: '5. Dónde y cuánto tiempo', p: ['Tus datos se almacenan en los servidores de los proveedores anteriores, que pueden estar fuera de tu país. Los registros técnicos se purgan automáticamente (por ejemplo, registros del motor a los 7 días y comprobaciones a los 14). Tus listas se conservan mientras tengas cuenta.'] },
    { h: '6. Tus derechos', p: [`Puedes pedir acceso, corrección o eliminación de tus datos escribiendo a ${legal.email}. Puedes exportar tus listas desde el panel y eliminar tu cuenta.`] },
    { h: '7. Almacenamiento en tu navegador', p: ['Usamos el almacenamiento local del navegador únicamente para mantener tu sesión y preferencias de pantalla. No usamos cookies de publicidad ni de seguimiento.'] },
    { h: '8. Cambios', p: [`Si cambiamos esta política, lo avisaremos en el panel. Última actualización: ${legal.updated}.`] },
  ],
});
