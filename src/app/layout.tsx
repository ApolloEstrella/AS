import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Ledgerly | Accounting",
  description: "A clear view of your business finances.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className="h-full antialiased">
      <body className="min-h-full">{children}</body>
    </html>
  );
}
