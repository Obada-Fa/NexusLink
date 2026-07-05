import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "NexusLink Host",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body style={{ margin: 0, background: "#0a0a0f", color: "#e5e5e5" }}>
        {children}
      </body>
    </html>
  );
}
